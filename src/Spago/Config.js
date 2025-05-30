import Yaml from "yaml";

const getOrElse = (node, key, fallback) => {
  if (!node.has(key)) {
    node.set(key, fallback);
  }
  return node.get(key);
}

export function addPackagesToConfigImpl(doc, isTest, newPkgs) {
  const pkg = doc.get("package");

  const deps = (() => {
    if (isTest) {
      const test = getOrElse(pkg, "test", doc.createNode({ main: "Test.Main", dependencies: [] }));
      return getOrElse(test, "dependencies", doc.createNode([]));
    } else {
      return getOrElse(pkg, "dependencies", doc.createNode([]))
    }
  })();

  // Stringify this collection as
  //  - dep1
  //  - dep2
  // rather than
  //  [ dep1, dep2 ]
  deps.flow = false;

  // Gather all deps, old and new, in a new set
  let depsSet = new Set(deps.toJSON());
  for (const pkg of newPkgs) {
    depsSet.add(pkg);
  }

  // now we go through the items - if an item is in the set we delete the name
  // from the set and add the package to a new list.
  // If it's not in the set then we do nothing and just discard it, as it's a duplicate
  let newItems = [];
  for (const el of deps.items) {
    if (Yaml.isScalar(el) && depsSet.has(el.value)) {
      depsSet.delete(el.value);
      newItems.push(el);
    }
    // If it's not a scalar then we have a version range, and we are dealing with a map
    if (Yaml.isMap(el) && depsSet.has(el.items[0].key)) {
      depsSet.delete(el.value);
      newItems.push(el);
    }
  }
  // any remaining values in the set are the new packages. We add them too
  for (const newPkg of depsSet) {
    newItems.push(doc.createNode(newPkg));
  }

  newItems.sort();
  deps.items = newItems;
}

export function removePackagesFromConfigImpl(doc, isTest, shouldRemove) {
  const pkg = doc.get("package");

  const deps = isTest ? pkg.get("test").get("dependencies") : pkg.get("dependencies");
  let newItems = [];
  for (const el of deps.items) {
    if (
      (Yaml.isScalar(el) && shouldRemove(el.value)) ||
      (Yaml.isMap(el) && shouldRemove(el.items[0].key))
    ) {
      continue;
    }
    newItems.push(el);
  }
  newItems.sort();
  deps.items = newItems;
}

export function addRangesToConfigImpl(doc, rangesMap) {
  const deps = doc.get("package").get("dependencies");

  // if a dependency is an object then we know it has a range, otherwise we
  // look up in the map of ranges and add it from there.
  let newItems = [];
  for (const el of deps.items) {
    // If it's not a scalar then we have a version range, let it be
    if (Yaml.isMap(el)) {
      newItems.push(el);
    }
    if (Yaml.isScalar(el)) {
      let newEl = new Map();
      newEl.set(el.value, rangesMap[el.value]);
      newItems.push(doc.createNode(newEl));
    }
  }

  newItems.sort();
  deps.items = newItems;
}

// Note: this function assumes a few things:
// - the `publish` section exists
// - the new element does not already exist in the list (it just appends it)
export function addOwnerImpl(doc, owner) {
  const publish = doc.get("package").get("publish");
  let owners = getOrElse(publish, "owners", doc.createNode([]));
  owners.items.push(doc.createNode(owner));
}

export function setPackageSetVersionInConfigImpl(doc, version) {
  doc.setIn(["workspace", "packageSet", "registry"], version);
}

export function migrateV1ConfigImpl(doc) {
  // see here for more info about the visitor: https://eemeli.org/yaml/#finding-and-modifying-nodes
  let hasChanged = false;
  Yaml.visit(doc, {
    Pair(_idx, pair, _path) {
      // A previous version of the config used underscores in the config keys,
      // but we standardised on camelCase instead.
      // So here we crawl through the keys of each YamlMap and convert all the keys
      // to camelCase.
      if (pair.key && Yaml.isScalar(pair.key)) {
        pair.key.value = pair.key.value.replaceAll(/_./g, function (match) {
          hasChanged = true;
          return match.charAt(1).toUpperCase();
        });
      }
    }
  });
  if (hasChanged) {
    return doc;
  }
}

export function addPublishLocationToConfigImpl(doc, location) {
  doc.setIn(["package", "publish", "location"], location);
}
