# The .seal files of a configuration, and its entry.
#
# Given its entry file (./config/Main.seal), they are that file, the files of the classes it names,
# and of those they name, from the folder the entry is in and from the libraries' folders: Seal keeps
# each type in a file named after it, so Users.add() in the code finds Users.seal. Files that nothing
# names are left out, so one folder can hold several machines, each its own entry (Main.seal,
# Laptop.seal) sharing the rest, and a library costs nothing until a configuration names it. The
# entry's class is the one its file is named after, and its main() is what runs.
#
# Given a folder, they are all of its .seal files, and the entry is Main.seal; from the libraries,
# still only the files those name.
{ lib }:
src: libraries:
let
  inherit (builtins) concatMap filter isString readFile readFileType split;

  asPath = p: if builtins.isPath p then p else /. + toString p;
  path = asPath src;
  isFile = readFileType path == "regular";
  root = if isFile then dirOf path else path;
  libraryRoots = map asPath libraries;

  sealFiles = dir: filter (f: lib.hasSuffix ".seal" (toString f)) (lib.filesystem.listFilesRecursive dir);
  own = sealFiles root;
  all = own ++ concatMap sealFiles libraryRoots;
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

  files = if isFile then reach [ ] [ path ] else reach [ ] own;

  # The files under one folder, in their folders below it (a package's: minecraft/ for package
  # minecraft), as the host reads them; nothing for a folder none of them is in.
  under = dir:
    let these = filter (f: lib.path.hasPrefix dir f) files; in
    lib.optional (these != [ ]) (lib.fileset.toSource { root = dir; fileset = lib.fileset.unions these; });

  nested = filter (l: lib.path.hasPrefix root l || lib.path.hasPrefix l root) libraryRoots;
in
assert lib.assertMsg (!isFile || lib.hasSuffix ".seal" (toString path))
  "seal-nix: ${toString path} isn't a .seal file; give the configuration's entry, as ./config/Main.seal, or its folder";
assert lib.assertMsg (nested == [ ])
  "seal-nix: the library ${toString (lib.head nested)} and the configuration's folder ${toString root} are one inside the other; give a library a folder of its own";
{
  inherit root files;
  main = if isFile then typeName path else "Main";

  # Those files alone, in their folders: the configuration's, then each library's, for the host to
  # compile together.
  dirs = concatMap under ([ root ] ++ libraryRoots);
}
