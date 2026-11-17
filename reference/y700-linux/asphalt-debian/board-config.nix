# Evaluate the pinned upstream board layers without building a NixOS userspace.
let
  lib = {
    kernel = { yes = "y"; no = "n"; module = "m"; };
    inherit (builtins) concatMap any;
    splitString = sep: s: builtins.filter builtins.isString (builtins.split sep s);
    unique = xs: builtins.attrNames (lib.genAttrs xs (_: true));
    genAttrs = names: f: builtins.listToAttrs (map (name: { inherit name; value = f name; }) names);
    hasPrefix = prefix: value: builtins.substring 0 (builtins.stringLength prefix) value == prefix;
    optionalAttrs = condition: attrs: if condition then attrs else {};
    filterAttrs = f: attrs: builtins.listToAttrs (builtins.concatMap
      (name: if f name attrs.${name} then [{inherit name; value = attrs.${name};}] else [])
      (builtins.attrNames attrs));
  };
  kernel = ../asphalt-upstream/pkgs/linux-kernel;
  board = import (kernel + "/sm8475/asphalt") { inherit lib; baseKernel = {}; llvmPackages_23 = {}; openssl = {}; };
in import (kernel + "/config/common.nix") { inherit lib; inherit (board) configfile; }
   // import (kernel + "/sm8475/config.nix") { inherit lib; }
   // board.configOverrides
