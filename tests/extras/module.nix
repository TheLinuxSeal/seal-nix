# A module that needs a specialArg to declare its options, as one importing from `inputs` does:
# with specialArgs.flavour = "seal", it declares myapp.seal.enable.
{ lib, flavour, ... }:
{
  options.myapp.${flavour}.enable = lib.mkEnableOption "my app, ${flavour} flavour";
}
