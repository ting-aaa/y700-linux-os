# Qualified dual-kernel removable releases. Called only with a known edition.
sd_release() {
    edition=$1
    case "$edition" in
        dev12.12)
            sd_root=5ebb7a1ffcbdb0b4265ed7b662965592e9b4f038dd5f5d6d779cb0303a00ada3
            sd_esp=1f6d75c17b5f38ff69d57e13c671bd0c1cbccf0c74cf1ea3f79e2011445ed091
            sd_inventory=ef9dea42fb4990e05025bdaa9ac6aac8b0f49e48f14cd57a4ff13d0207e08047
            sd_ledger=5fa586a125d52580771c923bec05985e32906be36acf1b88dec29e5791b89ccd
            sd_initrd=f024ed471d61cdad1033b6c88feeeb1e57a0690874154772a391ba3924211fc4
            sd_primary=49a12578e3a92c39a3636c51a5fb06be932dfb915e47ac6b62794dda9b152d04
            sd_compat=3de4e351392958102ac3a325d2e5f517d206ba840a1307f25d9ba23574db3dfe
            sd_disk_id=d17cdf76-0a43-57e1-be65-a009653b8c77
            sd_esp_id=312462af-8174-5749-ae6c-b4fae22ab28d
            sd_root_id=fbb98ccc-c5e5-5fd3-b055-b51b1dfa69d1
            ;;
        dev12.13)
            sd_root=6155d87d5d5b9d5557e86362f09fb17328aef200861e94eb292a669c35659c7c
            sd_esp=cdd0e35bf0d0cd859f521bf74fafa594388ea3093c33ea81c189da56cb3dea0d
            sd_inventory=5f991636f274f7d21c38f4eaf4e119d6491a1c7c901fdb818518548333574098
            sd_ledger=3d77058cde509e6f3256f332d4a2469d9448490ce6628001defdadd08711b5b8
            sd_initrd=4ec82c1ba1d966e3fe9b3c3224ff029dfca08d799449ad4e72825d0b5c8916e0
            sd_primary=42fa8049831090e98069d05d75c54c494511aa1e415dbc81c986fde24ca1ff69
            sd_compat=f721441c0404623cd494e8539e561b1340e6207edc1b59430390e96db09f213e
            sd_disk_id=8cd20f2b-d0cb-547e-abf6-9c6563c3b281
            sd_esp_id=3b20760e-9df3-5bcf-b9b2-da777b68cf5e
            sd_root_id=5b6f7287-d3c1-5d15-8287-f07e40c2fdef
            ;;
        *) echo "Unsupported dual-kernel SD release: $edition" >&2; return 1 ;;
    esac
    sd_suffix=12${edition##*.}
    sd_name=y700-sd-12-${edition##*.}
    sd_boot_uuid=12DC-$sd_suffix
}
