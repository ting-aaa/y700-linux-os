let
  base = ../asphalt-upstream/pkgs/u-boot;
  board = import (base + "/sm8475/asphalt");
  soc = (import (base + "/platforms.nix")).qualcomm;
in {
  patches = map toString (soc.patches ++ board.patches);
  config = import (base + "/sm8475/config.nix") + import (base + "/boot-actions.nix") {
    profile = board.bootActionProfile;
    confirmationNonGptLunMask = board.bootActionConfirmationNonGptLunMask;
    androidNonGptLunMask = board.bootActionAndroidNonGptLunMask;
    chargerConfirmationPath = board.bootActionChargerConfirmationPath;
  } + board.config;
  inherit (soc) defconfig baseConfig;
}
