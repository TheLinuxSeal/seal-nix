# The .seal files of a configuration, and its entry.
#
# Given its entry file (./config/Main.seal), they are that file, the files of the classes it names,
# and of those they name, from the folder the entry is in: Seal keeps each type in a file named
# after it, so Users.add() in the code finds Users.seal. Files that nothing names are left out, so
# one folder can hold several machines, each its own entry (Main.seal, Laptop.seal) sharing the
# rest. The entry's class is the one its file is named after, and its main() is what runs.
#
# Given a folder, they are all of its .seal files, and the entry is Main.seal.
{ lib }:
src:
let
  inherit (builtins) concatMap filter isString readFile readFileType split;

  path = if builtins.isPath src then src else /. + toString src;
  isFile = readFileType path == "regular";
  root = if isFile then dirOf path else path;

  all = filter (f: lib.hasSuffix ".seal" (toString f)) (lib.filesystem.listFilesRecursive root);
  typeName = f: lib.removeSuffix ".seal" (baseNameOf (toString f));
  words = f: filter (w: isString w && w != "") (split "[^A-Za-z0-9_]+" (readFile f));

  # The files whose types the frontier's name, until no more are found.
  reach = done: frontier:
    if frontier == [ ] then done
    else
      let
        seen = done ++ frontier;
        named = lib.genAttrs (lib.unique (concatMap words frontier)) (_: true);
        next = filter (f: named ? ${typeName f} && !(lib.elem f seen)) all;
      in
      reach seen next;

  files = if isFile then reach [ ] [ path ] else all;
in
assert lib.assertMsg (!isFile || lib.hasSuffix ".seal" (toString path))
  "seal-nix: ${toString path} isn't a .seal file; give the configuration's entry, as ./config/Main.seal, or its folder";
{
  inherit root files;
  main = if isFile then typeName path else "Main";

  # Those files alone, in their folders, for the host to compile.
  dir = lib.fileset.toSource { inherit root; fileset = lib.fileset.unions files; };
}
