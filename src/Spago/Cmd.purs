module Spago.Cmd where

import Spago.Prelude

import Data.Array as Array
import Data.Foldable (traverse_)
import Data.Posix (Pid)
import Data.String (Pattern(..))
import Data.String as String
import Data.Time.Duration (Milliseconds(..))
import Node.ChildProcess.Types (Exit(..), KillSignal, inherit, pipe)
import Node.Library.Execa as Execa
import Node.Platform as Platform
import Node.Process as Process
import Partial.Unsafe (unsafeCrashWith, unsafePartial)
import Spago.Path as Path
import Unsafe.Coerce (unsafeCoerce)

data StdinConfig
  = StdinPipeParent
  | StdinNewPipe
  | StdinWrite String

type ExecResult =
  { canceled :: Boolean
  , escapedCommand :: String
  , exit :: Exit
  , exitCode :: Maybe Int
  , killed :: Boolean
  , message :: String
  , originalMessage :: Maybe String
  , pid :: Maybe Pid
  , shortMessage :: String
  , signal :: Maybe KillSignal
  , signalDescription :: Maybe String
  , stderr :: String
  , stderrError :: Maybe Error
  , stdinError :: Maybe Error
  , stdout :: String
  , stdoutError :: Maybe Error
  , timedOut :: Boolean
  }

exitedOk :: Either ExecResult ExecResult -> Boolean
exitedOk = either identity identity >>> case _ of
  { exit: Normally 0 } -> true
  _ -> false

exit :: Either ExecResult ExecResult -> Exit
exit = either identity identity >>> _.exit

printExecResult :: ExecResult -> String
printExecResult r = Array.intercalate "\n"
  [ "escapedCommand: " <> show r.escapedCommand
  , "canceled: " <> show r.canceled
  , "exit: " <> show r.exit
  , "exitCode: " <> show r.exitCode
  , "signal: " <> show r.signal
  , "signalDescription: " <> show r.signalDescription
  , "pid: " <> show r.pid
  , "killed: " <> show r.killed
  , "timedOut: " <> show r.timedOut
  , "shortMessage: " <> show r.shortMessage
  , "message: " <> show r.message
  , "originalMessage: " <> show r.originalMessage
  , "stdinError: " <> show r.stdinError
  , "stdoutError: " <> show r.stdoutError
  , "stderrError: " <> show r.stderrError
  , "stderr:"
  , r.stderr
  , ""
  , "stdout:"
  , r.stdout
  , ""
  ]

type ExecOptions =
  { pipeStdin :: StdinConfig
  , pipeStdout :: Boolean
  , pipeStderr :: Boolean
  , cwd :: Maybe GlobalPath
  , shell :: Boolean
  }

defaultExecOptions :: ExecOptions
defaultExecOptions =
  { pipeStdin: StdinNewPipe
  , pipeStdout: true
  , pipeStderr: true
  , cwd: Nothing
  , shell: false
  }

spawn :: forall m. MonadAff m => String -> Array String -> ExecOptions -> m Execa.ExecaProcess
spawn cmd args opts = liftAff do
  let
    stdinOpt = case opts.pipeStdin of
      StdinPipeParent -> Just inherit
      StdinWrite _ -> Just pipe
      StdinNewPipe -> Just pipe
  subprocess <- Execa.execa cmd args _
    { cwd = Path.toRaw <$> opts.cwd
    , stdin = stdinOpt
    , stdout = Just pipe
    , stderr = Just pipe
    , shell = case opts.shell of
        -- TODO: execa doesn't support the boolean option yet
        true -> Just (unsafeCoerce true)
        false -> Nothing
    }

  case opts.pipeStdin of
    StdinWrite s | Just { writeUtf8End } <- subprocess.stdin -> writeUtf8End s
    _ -> pure unit

  when (opts.pipeStderr) do
    traverse_ _.pipeToParentStderr subprocess.stderr
  when (opts.pipeStdout) do
    traverse_ _.pipeToParentStdout subprocess.stdout

  pure subprocess

joinProcess :: forall m. MonadAff m => Execa.ExecaProcess -> m (Either ExecResult ExecResult)
joinProcess cp = do
  result <- liftAff $ cp.getResult
  case result.exit of
    Normally 0 -> pure $ Right result
    _ -> pure $ Left result

exec :: forall m. MonadAff m => GlobalPath -> Array String -> ExecOptions -> m (Either ExecResult ExecResult)
exec cmd args opts = liftAff do
  result <- _.getResult =<< spawn (Path.toRaw cmd) args opts
  case result.exit of
    Normally 0 -> pure $ Right result
    _ -> pure $ Left result

kill :: Execa.ExecaProcess -> Aff ExecResult
kill cp = liftAff do
  void $ cp.killForced $ Milliseconds 2_000.0
  cp.getResult >>= \r -> case r.exit of
    Normally 0 -> unsafeCrashWith ("Tried to kill the process, failed. Result:\n" <> printExecResult r)
    _ -> pure r

getStdout :: Either ExecResult ExecResult -> String
getStdout = either _.stdout _.stdout

getStderr :: Either ExecResult ExecResult -> String
getStderr = either _.stderr _.stderr

-- | Try to find one of the flags in a list of Purs args
-- | For example, trying to find the `output` arg
-- | we would run
-- | `findFlags { flags: [ "-o", "--output" ], args }`
-- | where `args` is one of the 6 variants below:
-- | - args are just one element:
-- |    - `[ "--output"]`
-- | - args are two separate array elements:
-- |    - `[ "-o", "dir"]`
-- |    - `[ "--output", "dir"]`
-- | - args are stored in the same array element
-- |    - `[ "-o dir"]`
-- |    - `[ "--output dir"]`
-- |    - `[ "--output=dir"]`
findFlag :: { flags :: Array String, args :: Array String } -> Maybe String
findFlag { flags, args } = if argsLen == 0 then Nothing else go 0
  where
  argsLen = Array.length args
  lastArgIdx = argsLen - 1

  go idx = do
    let currentArg = unsafePartial $ Array.unsafeIndex args idx
    case Array.findMap (\flag -> stripFlag flag currentArg) flags of
      Just (Tuple isOneCharFlag restOfArg) -> case restOfArg of
        -- If the flag is the entirety of the arg, we need to look at the next arg:
        "" -> case Array.index args (idx + 1) of
          -- If there's a next arg we return it
          Just next -> Just next
          -- If there's not then this was a boolean flag
          Nothing -> Just ""
        _ -> dropExtra isOneCharFlag restOfArg
      Nothing -> case idx < lastArgIdx of
        true -> go (idx + 1)
        false -> Nothing

  stripFlag :: String -> String -> Maybe (Tuple Boolean String)
  stripFlag flag arg =
    Tuple (isSingleCharFlag flag) <$> String.stripPrefix (Pattern flag) arg

  dropExtra :: Boolean -> String -> Maybe String
  dropExtra isOneCharFlag restOfArg =
    if isOneCharFlag then dropSpace restOfArg
    else dropSpace restOfArg <|> dropEquals restOfArg
    where
    dropSpace = String.stripPrefix (Pattern " ")
    dropEquals = String.stripPrefix (Pattern "=")

  isSingleCharFlag = eq (Just 1) <<< map String.length <<< String.stripPrefix (Pattern "-")

getExecutable :: ∀ a. String -> Spago (LogEnv a) { cmd :: GlobalPath, output :: String }
getExecutable command =
  case Process.platform of
    Just Platform.Win32 -> do
      -- On Windows, we often need to call the `.cmd` version
      let cmd1 = mkCmd command (Just "cmd")
      askVersion cmd1 true >>= case _ of
        Right r -> pure { cmd: cmd1, output: r.stdout }
        Left r -> do
          let cmd2 = mkCmd command Nothing
          logDebug [ "Failed to find purs.cmd. Trying with just purs...", show r.message ]
          askVersion cmd2 false >>= case _ of
            Right r' -> pure { cmd: cmd2, output: r'.stdout }
            Left r' -> complain r'
    _ -> do
      -- On other platforms, we just call `purs`
      let cmd1 = mkCmd command Nothing
      askVersion cmd1 false >>= case _ of
        Right r -> pure { cmd: cmd1, output: r.stdout }
        Left r -> complain r
  where
  askVersion cmd shell = exec cmd [ "--version" ] defaultExecOptions { pipeStdout = false, pipeStderr = false, shell = shell }

  mkCmd cmd maybeExtension = Path.global $ cmd <> maybe "" (append ".") maybeExtension

  complain err = do
    logDebug $ printExecResult err
    die [ "Failed to find " <> command <> ". Have you installed it, and is it in your PATH?" ]
