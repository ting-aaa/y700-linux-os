#!/usr/bin/env python3
"""Use the prepared kernel's real TX3 configuration path in a transport-free module."""
import re
import sys
from pathlib import Path


def definition(source, name):
    # Kernel function bodies end with a closing brace at the start of a line.
    match = re.search(rf"^[^\n;{{}}]*\b{name}\([^;{{}}]*\)\n\{{\n.*?^\}}$",
                      source, flags=re.MULTILINE | re.DOTALL)
    if not match:
        raise ValueError(f"Missing definition for {name}")
    return match.group()


def structure(source, name):
    return re.search(rf"^struct {name} \{{\n.*?^\}}(?: __packed)?;$",
                     source, flags=re.MULTILINE | re.DOTALL).group()


def main(kernel, machine, output):
    q6 = kernel / "sound/soc/qcom/qdsp6"
    reach = (q6 / "audioreach.c").read_text()
    lpass = (q6 / "q6apm-lpass-dais.c").read_text()
    board = machine.read_text()
    declarations = []
    for name, macro in (
        ("apm_codec_dma_module_intf_cfg", "APM_CDMA_INTF_CFG_PSIZE"),
        ("apm_module_frame_size_factor_cfg", "APM_FS_CFG_PSIZE"),
        ("apm_module_hw_ep_power_mode_cfg", "APM_HW_EP_PMODE_CFG_PSIZE"),
        ("apm_module_hw_ep_mf_cfg", "APM_HW_EP_CFG_PSIZE"),
    ):
        declarations.append(structure(reach, name))
        declarations.append(re.search(rf"^#define {macro}\b.*$", reach, re.MULTILINE).group())
    declarations.extend(structure(lpass, name) for name in ("q6apm_dai_priv_data", "q6apm_lpass_dai_data"))
    declarations.extend(definition(reach, name) for name in (
        "__audioreach_alloc_pkt", "audioreach_alloc_apm_cmd_pkt", "audioreach_set_default_channel_mapping",
        "audioreach_codec_dma_set_media_format"))
    declarations.extend(definition(lpass, name) for name in ("q6dma_set_channel_map", "q6dma_hw_params"))
    declarations.append(structure(board, "qcom_snd_soc_common"))
    declarations.append(re.search(r"^static const struct snd_soc_dapm_widget y700_dapm_widgets\[\] = \{.*?^\};",
                                  board, re.MULTILINE | re.DOTALL).group())
    if "static int y700_snd_prepare(" in board:
        declarations.append(definition(board, "y700_snd_prepare"))
    declarations.append(re.search(r"^static const struct qcom_snd_soc_common y700_priv_data = \{.*?^\};",
                                  board, re.MULTILINE | re.DOTALL).group())
    output.write_text("\n\n".join(declarations) + "\n")


if __name__ == "__main__":
    main(*(Path(arg) for arg in sys.argv[1:]))
