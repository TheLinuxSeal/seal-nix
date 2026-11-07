# What a SealNix configuration uses: every `Config.a.b.c` and `Packages.x.y` its .seal files write,
# resolved against NixOS's options and nixpkgs, with each option's type. SealNix's host generates
# Seal classes for these alone, so a configuration can use any option and any package without
# Seal compiling all of NixOS (30 000 options) and nixpkgs (over 100 000 packages) each time.
#
# Names are Nix's. Where Nix allows what Seal doesn't, Seal writes `_`: experimental-features is
# experimental_features, systemd-boot is systemd_boot, and a Seal keyword gets one after it, package_.
{ lib, options, pkgs }:
files:
let
  inherit (builtins) attrNames concatLists elem filter foldl' head isAttrs isBool isFloat isInt isList isString
    length map match split tail tryEval;

  sealKeywords = [
    "class" "struct" "unique" "interface" "enum" "package" "import" "assert" "switch" "throw" "try" "catch"
    "finally" "case" "default" "abstract" "extends" "implements" "instanceof" "this" "public" "private" "static"
    "const" "pure" "int" "char" "uint" "bit" "float" "double" "void" "addr" "handle" "fixed" "ufixed" "new" "delete"
    "return" "if" "else" "while" "for" "break" "continue" "sizeof" "alignof" "super" "null" "true" "false"
  ];

  # A Nix name as Seal writes it; SealNix.java's sealName is the same.
  sealName = n:
    let
      s = lib.stringAsChars (c: if match "[A-Za-z0-9_]" c != null then c else "_") n;
      s' = if s == "" || match "[0-9].*" s != null then "_" + s else s;
    in
    if elem s' sealKeywords then s' + "_" else s';

  # An option NixOS keeps for an old name, which its manual doesn't show (services.oauth2_proxy).
  hidden = set: n:
    let r = tryEval (let v = set.${n}; in lib.isOption v && (v.visible or true) == false);
    in r.success && r.value;

  # The child of a Nix attribute set that Seal names `seg`, by its Nix name, or null. Where two Nix
  # names are one Seal name (oauth2-proxy, and oauth2_proxy, its old name), the one shown wins.
  childNamed = set: seg:
    if set ? ${seg} && !(hidden set seg) then seg
    else
      let
        r = tryEval (filter (n: sealName n == seg) (attrNames set));
        all = if r.success then r.value else [ ];
        shown = filter (n: !(hidden set n)) all;
      in
      if shown != [ ] then head shown else if all != [ ] then head all else null;

  get = set: name: let r = tryEval set.${name}; in if r.success then r.value else null;

  # ---- Reading the configuration -----------------------------------------------------------------

  text = lib.concatMapStrings (f: "\n" + builtins.readFile f) files;

  # Each `word.a.b.c` the files write, as [ "a" "b" "c" ].
  chainsAfter = word:
    map (m: tail (lib.splitString "." (head m)))
      (filter isList (split "[^A-Za-z0-9_.]${word}((\\.[A-Za-z_][A-Za-z0-9_]*)+)" text));

  # Methods of the generated classes, which a chain may go on with: they aren't names.
  methods = [ "get" "set" "has" "add" "size" "isEmpty" "contains" "setRaw" ];

  # ---- Option types ------------------------------------------------------------------------------

  # A whole NixOS inside an option (containers.<name>.config, specialisation): too big to generate.
  isNixos = set: isAttrs set && set ? system && set ? boot && set ? services;

  unwrap = t:
    if elem t.name [ "nullOr" "unique" "uniq" ] then unwrap t.nestedTypes.elemType
    else if t.name == "coercedTo" then unwrap t.nestedTypes.finalType
    else t;

  alternatives = t:
    let u = unwrap t; in
    if u.name == "either" then alternatives u.nestedTypes.left ++ alternatives u.nestedTypes.right else [ u ];

  scalarKinds = [ "str" "int" "float" "bit" "pkg" ];

  # A type that holds one value: bit, int, float, str or pkg; null if it isn't one.
  scalar = t:
    let n = t.name; in
    if elem n [ "bool" "boolByOr" ] then "bit"
    else if n == "int" || match "(.*Int[0-9]*|intBetween|int[A-Z].*)" n != null then "int"
    else if match "(float|number.*|.*Float)" n != null then "float"
    else if elem n [ "str" "string" "path" "strMatching" "separatedString" "nonEmptyStr" "singleLineStr" "absolutePath"
      "pathInStore" "externalPath" "passwdEntry" "lines" "commas" "envVar" "goDuration" "kernelParam" ]
      || lib.hasPrefix "passwdEntry" n || lib.hasPrefix "strMatching" n then "str"
    else if elem n [ "package" "shellPackage" ] then "pkg"
    else if n == "enum" then
      let values = t.functor.payload.values or [ ]; in
      if values != [ ] && lib.all isString values then "str"
      else if values != [ ] && lib.all isInt values then "int"
      else "nix"
    else null;

  # Types that are Nix itself, which a Seal configuration writes with Nix.raw or Nix.of.
  nixTypes = [ "anything" "unspecified" "raw" "functionTo" "function" "deferredModule" "tuple" "matrixOf"
    "attrTag" "pkgs" "optionType" ];

  # Attribute sets of anything, which take set(key, value) and the names a configuration writes.
  attrsTypes = [ "attrs" "nixpkgs-config" ];

  # A type of a module's own (sysctl, udev, systemd's options): what its description says it holds.
  byDescription = t:
    let d = tryEval (lib.toLower t.description); in
    if !d.success then "nix"
    else if match ".*(attribute set|list of|function).*" d.value != null then "nix"
    else if match ".*(string|path).*" d.value != null then "str"
    else if match ".*integer.*" d.value != null then "int"
    else if match ".*boolean.*" d.value != null then "bit"
    else "nix";

  # The SealNix kind of an option of type t at loc, as SealNix.java takes it.
  kind = depth: loc: t:
    let
      u = unwrap t;
      n = u.name;
      s = scalar u;
    in
    if depth > 6 || length loc > 16 then { k = "nix"; }
    else if n == "either" then union depth loc u
    else if n == "listOf" then
      let e = kind (depth + 1) (loc ++ [ "*" ]) u.nestedTypes.elemType; in
      if e.k == "sub" then e // { k = "listsub"; }
      else if elem e.k (scalarKinds ++ [ "nix" ]) then { k = "list"; inherit e; }
      else { k = "list"; e = { k = "nix"; }; }
    else if elem n [ "attrsOf" "lazyAttrsOf" ] then
      let e = kind (depth + 1) (loc ++ [ "<name>" ]) u.nestedTypes.elemType; in
      if e.k == "sub" then e // { k = "attrssub"; names = namesAt loc; }
      else if elem e.k (scalarKinds ++ [ "nix" ]) || (e.k == "list" && e.e.k != "nix") then
        { k = "attrs"; inherit e; names = namesAt loc; } // lib.optionalAttrs (e.k == "nix") { nameTypes = nameTypes (namesAt loc); }
      else { k = "attrs"; e = { k = "nix"; }; names = namesAt loc; nameTypes = nameTypes (namesAt loc); }
    else if n == "submodule" then
      let sub = tryEval (u.getSubOptions loc); in
      if !sub.success || isNixos sub.value then { k = "nix"; }
      else {
        k = "sub";
        options = everything sub.value;
        # Whether it takes settings it doesn't declare: home-manager's can't say without a configuration.
        freeform = let r = tryEval (u.nestedTypes ? freeformType); in r.success && r.value;
      }
    else if s != null then { k = s; }
    else if elem n attrsTypes then { k = "attrs"; e = { k = "nix"; }; names = namesAt loc; nameTypes = nameTypes (namesAt loc); }
    else if elem n nixTypes then { k = "nix"; }
    else { k = byDescription u; };

  # either a or b: the kind most configurations mean. One that may be an attribute set is a set of
  # settings (git's, Hyprland's, which may also be a value or a list); else a string over a number,
  # over a list.
  union = depth: loc: t:
    let
      kinds = map (kind (depth + 1) loc) (alternatives t);
      first = ks: filter (x: elem x.k ks) kinds;
      pick = foldl' (found: ks: if found != null then found else let f = first ks; in if f == [ ] then null else head f) null
        [ [ "attrs" ] [ "sub" ] [ "str" ] [ "int" ] [ "float" ] [ "bit" ] [ "pkg" ] [ "list" ] ];
    in
    if pick == null then { k = "nix"; } else pick;

  # The kind of an option: untyped ones (unspecified, anything) take their default value's.
  optionKind = opt:
    let u = unwrap opt.type; in
    if elem u.name [ "unspecified" "anything" ] then
      let
        d = tryEval (opt.default or null);
        v = d.value;
        strings = tryEval (isList v && v != [ ] && lib.all isString v);
      in
      if !d.success || v == null then { k = "nix"; }
      else if isBool v then { k = "bit"; }
      else if isInt v then { k = "int"; }
      else if isFloat v then { k = "float"; }
      else if isString v then { k = "str"; }
      else if strings.success && strings.value then { k = "list"; e = { k = "str"; }; }
      else { k = "nix"; }
    else kind 0 opt.loc opt.type;

  optionSpec = opt: { kind = "opt"; type = optionKind opt; };

  # Every option under a namespace (or a submodule's), as SealNix.java takes them.
  everything = set:
    let
      groups = builtins.groupBy sealName (attrNames (removeAttrs set [ "_module" ]));
      winners = map (s: if length groups.${s} == 1 then head groups.${s} else childNamed set s) (attrNames groups);
    in
    lib.filterAttrs (n: v: v != null) (lib.genAttrs winners (n: specOf set.${n}));

  # An option's spec, or a namespace's, or null where evaluating it fails: forced all the way down
  # here, where a failure can be caught, rather than when it becomes JSON (home-manager's
  # nixpkgs.* options can't be evaluated without a configuration).
  specOf = v:
    let
      r = tryEval (
        let spec =
          if lib.isOption v then (if v.readOnly or false then null else optionSpec v)
          else if isAttrs v && !(lib.isDerivation v) then { kind = "ns"; children = everything v; }
          else null;
        in builtins.deepSeq spec spec);
    in
    if r.success then r.value else null;

  # ---- Which options the configuration names -------------------------------------------------------

  configChains = chainsAfter "Config";

  # What a chain reaches: { selected = tree of Nix names, true where a whole option or namespace is
  # meant; names = [ { at = loc; name } ], the names it writes into attribute sets (users.users.seal);
  # unknown = what it names that NixOS hasn't }.
  follow = node: path: segs:
    if segs == [ ] then { selected = true; names = [ ]; unknown = [ ]; }
    else
      let name = childNamed node (head segs); in
      if name == null then
        if elem (head segs) methods then { selected = null; names = [ ]; unknown = [ ]; }
        else {
          selected = null;
          names = [ ];
          unknown = [{
            what = "option";
            name = if path == [ ] then "Config" else "Config." + lib.concatMapStringsSep "." sealName path;
            missing = head segs;
            candidates = map sealName (attrNames (removeAttrs node [ "_module" ]));
          }];
        }
      else
        let child = get node name; in
        if child == null then { selected = null; names = [ ]; unknown = [ ]; }
        else if lib.isOption child then { selected = { ${name} = true; }; names = namesIn child.loc child.type (tail segs); unknown = [ ]; }
        else if isAttrs child then
          let r = follow child (path ++ [ name ]) (tail segs); in
          r // { selected = if r.selected == null then null else { ${name} = r.selected; }; }
        else { selected = null; names = [ ]; unknown = [ ]; };

  # The names a chain writes into the attribute sets it passes: users.users.seal.isNormalUser.
  namesIn = loc: t: segs:
    let u = unwrap t; in
    if segs == [ ] || elem (head segs) methods then [ ]
    else if elem u.name attrsTypes then [{ at = loc; name = head segs; }]
    else if elem u.name [ "attrsOf" "lazyAttrsOf" ] then
      [{ at = loc; name = head segs; }] ++ namesIn (loc ++ [ "<name>" ]) u.nestedTypes.elemType (tail segs)
    else if u.name == "submodule" then
      let sub = tryEval (u.getSubOptions loc); in
      if !sub.success then [ ] else namesInSet sub.value segs
    else [ ];

  namesInSet = set: segs:
    let name = childNamed set (head segs); child = if name == null then null else get set name; in
    if child == null then [ ]
    else if lib.isOption child then namesIn child.loc child.type (tail segs)
    else if isAttrs child && tail segs != [ ] then namesInSet child (tail segs)
    else [ ];

  # A name in an attribute set of anything takes the type of the first value the files give it:
  # nixpkgs.config.allowUnfree = true is a bit, serviceConfig.Type = "oneshot" a string.
  nameTypes = names: lib.genAttrs names (name:
    let
      found = filter isList (split "\\.${name}[ \t]*=[ \t]*(true|false|-?[0-9]+[.]?[0-9]*|\")" text);
      v = if found == [ ] then "\"" else head (head found);
    in
    if v == "true" || v == "false" then "bit"
    else if v == "\"" then "str"
    else if match ".*[.].*" v != null then "float"
    else "int");

  followed = map (follow options [ ]) configChains;
  allNames = concatLists (map (r: r.names) followed);
  # And `.serviceConfig.Type` anywhere, for an attribute set reached through a variable:
  # var hello = Config.systemd.services.get("hello"); hello.serviceConfig.Type = "oneshot";
  looseNames = option:
    map head (filter isList (split "\\.${sealName option}\\.([A-Za-z_][A-Za-z0-9_]*)" text));
  namesAt = loc:
    filter (n: !(elem n methods) && !(elem n sealKeywords))
      (lib.unique (map (x: x.name) (filter (x: x.at == loc) allNames) ++ looseNames (lib.last loc)));

  merge = a: b:
    if a == null then b else if b == null then a
    else if a == true || b == true then true
    else lib.zipAttrsWith (n: vs: foldl' merge null vs) [ a b ];

  selected = foldl' merge null (map (r: r.selected) followed);

  # The spec of what is selected under a namespace.
  specFor = node: sel:
    lib.filterAttrs (n: v: v != null) (lib.mapAttrs
      (name: s:
        let v = get node name; in
        if v == null then null
        else if s == true then specOf v
        else { kind = "ns"; children = specFor v s; })
      sel);

  # ---- Which packages ------------------------------------------------------------------------------

  # A chain of Seal names to a package: { tree = { kdePackages.kate."$pkg" = [ ... ]; } } or unknown.
  followPkg = set: path: segs:
    if segs == [ ] then { tree = null; unknown = [ ]; }
    else
      let name = childNamed set (head segs); v = if name == null then null else get set name; in
      if v == null then {
        tree = null;
        unknown = [{
          what = "package";
          name = if path == [ ] then "Packages" else "Packages." + lib.concatStringsSep "." path;
          missing = head segs;
          candidates = let r = tryEval (map sealName (attrNames set)); in if r.success then r.value else [ ];
        }];
      }
      else
        let isPkg = tryEval (lib.isDerivation v); in
        if isPkg.success && isPkg.value then { tree = { ${head segs} = { "$pkg" = path ++ [ name ]; }; }; unknown = [ ]; }
        else if isAttrs v then
          let r = followPkg v (path ++ [ name ]) (tail segs); in
          r // { tree = if r.tree == null then null else { ${head segs} = r.tree; }; }
        else { tree = null; unknown = [ ]; };

  pkgFollowed = map (followPkg pkgs [ ]) (chainsAfter "Packages");
  pkgTree = foldl' lib.recursiveUpdate { } (filter (t: t != null) (map (r: r.tree) pkgFollowed));
in
{
  options = if selected == null || selected == true then { } else specFor options selected;
  packages = pkgTree;
  unknown = concatLists (map (r: r.unknown) followed) ++ concatLists (map (r: r.unknown) pkgFollowed);
}
