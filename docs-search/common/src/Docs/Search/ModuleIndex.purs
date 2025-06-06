module Docs.Search.ModuleIndex where

import Prelude

import Control.Monad.State (execState, modify_)
import Control.Promise (Promise, toAffE)
import Data.Array as Array
import Data.Codec.JSON as CJ
import Data.Codec.JSON.Common as CJ.Common
import Data.Either (hush)
import Data.Foldable (foldl)
import Data.FoldableWithIndex (foldrWithIndex)
import Data.Lens ((%~))
import Data.Lens.Record (prop)
import Data.List (List, (:))
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Newtype (unwrap)
import Data.Search.Trie (Trie)
import Data.Search.Trie as Trie
import Data.Set (Set)
import Data.Set as Set
import Data.String.CodeUnits (toCharArray) as String
import Data.String.Common (split, toLower) as String
import Data.String.Pattern (Pattern(..))
import Data.Traversable (foldr, for_)
import Data.Tuple.Nested ((/\))
import Docs.Search.Config as Config
import Docs.Search.Declarations (Declarations(..))
import Docs.Search.Extra (stringToList)
import Docs.Search.Score (Scores, getPackageScore)
import Docs.Search.SearchResult (SearchResult(..))
import Docs.Search.Types (ModuleName(..), PackageInfo(..), PackageScore)
import Docs.Search.Types as Package
import Effect (Effect)
import Effect.Aff (Aff)
import JSON (JSON)
import Registry.PackageName (PackageName)
import Spago.Purs.Types as Graph
import Type.Proxy (Proxy(..))

-- | Module index that is actually stored in a JS file.
type PackedModuleIndex = Map PackageInfo (Set ModuleName)

packedModuleIndexCodec :: CJ.Codec PackedModuleIndex
packedModuleIndexCodec = CJ.Common.map Package.packageInfoCodec (CJ.Common.set Package.moduleNameCodec)

-- | "Expanded" module index that can be queried quickly.
type ModuleIndex =
  { packageModules :: Map PackageInfo (Set ModuleName)
  , modulePackages :: Map ModuleName PackageInfo
  , index :: Trie Char ModuleName
  }

type ModuleResult =
  { name :: ModuleName
  , package :: PackageInfo
  , score :: PackageScore
  }

unpackModuleIndex :: PackedModuleIndex -> ModuleIndex
unpackModuleIndex packageModules =
  flip execState { packageModules, modulePackages: Map.empty, index: mempty } do
    for_ (Map.toUnfoldableUnordered packageModules :: Array _)
      \(package /\ moduleNames) -> do
        for_ moduleNames \moduleName -> do
          modify_ $ _modulePackages %~ Map.insert moduleName package
          for_ (extractModuleNameParts moduleName) \part -> do
            let partPath = Array.toUnfoldable $ String.toCharArray part
            modify_ $ _index %~ Trie.insert partPath moduleName

-- | E.g. `"Data.Array.ST" -> ["data.array.st", "array.st", "st"]`.
extractModuleNameParts :: ModuleName -> List String
extractModuleNameParts =
  unwrap >>> String.toLower
    >>> String.split (Pattern ".")
    >>>
      foldl (\acc el -> el : map (_ <> "." <> el) acc) mempty

queryModuleIndex
  :: Scores
  -> ModuleIndex
  -> String
  -> Array ModuleResult
queryModuleIndex scores { index, modulePackages } query =
  let
    path = stringToList $ String.toLower query
  in
    Trie.queryValues path index
      # Array.fromFoldable
      # Array.nub
      <#>
        ( \name -> do
            package <- Map.lookup name modulePackages
            pure
              { name
              , package
              , score: getPackageScore scores package
              }
        )
      #
        Array.catMaybes

-- | Constructs a mapping from packages to modules
mkPackedModuleIndex :: Graph.ModuleGraphWithPackage -> Set PackageName -> Declarations -> PackedModuleIndex
mkPackedModuleIndex moduleGraph workspacePackages (Declarations trie) =
  addModulesForWorkspacePackages
    $ foldr (Map.unionWith Set.union) Map.empty
    $ extract <$> Trie.values trie
  where
  -- We need to get all the modules in the workspace packages and add them as a separate step,
  -- because if they don't have definitions (and are just re-exporting other things) then they won't
  -- have a docs.json file, and so they won't be in the trie.
  addModulesForWorkspacePackages index = foldrWithIndex addModulesForPackage index moduleGraph
  addModulesForPackage moduleName { package } index = case Set.member package workspacePackages of
    false -> index
    true -> Map.alter
      (Just <<< Set.insert (ModuleName moduleName) <<< fromMaybe Set.empty)
      (LocalPackage package)
      index

  extract
    :: List SearchResult
    -> Map PackageInfo (Set ModuleName)
  extract = foldr (Map.unionWith Set.union) Map.empty <<< map mkEntry
    where
    mkEntry (SearchResult { packageInfo, moduleName }) =
      Map.singleton packageInfo (Set.singleton moduleName)

loadModuleIndex :: Aff PackedModuleIndex
loadModuleIndex = do
  json <- toAffE $ load Config.moduleIndexLoadPath
  pure $ fromMaybe Map.empty $ hush $ CJ.decode packedModuleIndexCodec json

foreign import load
  :: String
  -> Effect (Promise JSON)

_modulePackages :: forall a b rest. (a -> b) -> { modulePackages :: a | rest } -> { modulePackages :: b | rest }
_modulePackages = prop (Proxy :: Proxy "modulePackages")

_index :: forall a b rest. (a -> b) -> { index :: a | rest } -> { index :: b | rest }
_index = prop (Proxy :: Proxy "index")
