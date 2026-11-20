# Approved USB inputs. Identify the release by the actual whole-initrd hash.
ram_profile() {
    case "$1" in
        ee4aceddc0302ff966c7d71f771e66302a50e83a3344e3f835e9a9cb40745946)
            release=dev12.6
            initrd_bytes=1261843044
            carrier_bytes=1250201600
            carrier_sha=775a6da7210c47a73ca240c2114ba3349c6d9e3134df4aab3c17dd9a9131f3be
            root_sha=74374ce94db4d88c20ba49d7cdff4cdbe6b5931ba047bea3460cede2c93b70cd
            package_count=1115
            package_sha=a5f46346523f60efb2545e290d209372daa983b094e42c37e7ced2cdb97b3d98
            ;;
        c2c0375bbdae3fb2ae0b1dcc6ac44e549cfc194eacc6e80e6b3925bce254579f)
            release=dev12.8
            initrd_bytes=1265087076
            carrier_bytes=1253445632
            carrier_sha=d4af2501573b90778c1dffb2006c6a6c338960625dfc80625a59154703bda278
            root_sha=2d03b3d2e312f1a425c5b8f657f20fddd45f07caa54b4a937590a720fa2cf511
            package_count=1124
            package_sha=a1a2498f80dc382dde6db1f3e0282193c10b78110089ea0db8ae002b1c3abb84
            ;;
        *) echo 'Unexpected RAM bundle initrd' >&2; return 1 ;;
    esac
}
