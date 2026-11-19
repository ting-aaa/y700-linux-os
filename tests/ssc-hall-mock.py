"""Extend libssc's networkless QRTR fixture with Qualcomm Hall reports."""

import multiprocessing
import runpy
import sys
import time
from ctypes import c_char_p
from pathlib import Path

from ssc_server import ssc
from ssc_server import ssc_common_pb2 as common


upstream = runpy.run_path(str(Path(__file__).parent / 'ssc-server'))
HALL_UID = (12, 12)


class HallServer(upstream['SSCMockingServer']):
    def send_event(self, uid, event_id, payload, node, port, transaction_id):
        result = common.SscClientResponse()
        result.uid.high, result.uid.low = uid
        entry = result.response.add()
        entry.msg_id = event_id
        entry.timestamp = time.monotonic_ns()
        entry.msg = payload
        packet = ssc.SSC.generate_report_large_indication(result.SerializeToString(), transaction_id)
        if self._qrtr.qrtr_sendto(self.sock, node, port, c_char_p(packet), len(packet)) != 0:
            raise RuntimeError('could not send Hall test report')

    def _reply_msg(self, node, port, incoming_msg):
        if incoming_msg[0] == upstream['QMI_REQUEST']:
            _, request, _ = ssc.SSC.parse_message_control_input(incoming_msg)
            message_id, high, low = ssc.SSC.parse_protobuf_client_request(request)
            if (high, low) == HALL_UID:
                if message_id == upstream['SSC_PROTOBUF_ENABLE_CONTINUOUS_MSG_ID']:
                    raise RuntimeError('Hall request incorrectly selected continuous mode')
                if message_id == upstream['SSC_PROTOBUF_ENABLE_REPORT_MSG_ID']:
                    print('Hall on-change subscription received', flush=True)
        super()._reply_msg(node, port, incoming_msg)

    def _sensor_measurement(self, high, low, node, port, transaction_id):
        assert (high, low) == HALL_UID
        config = common.SscConfigResponse(sample_rate=0.0)
        self.send_event(HALL_UID, 768, config.SerializeToString(), node, port, transaction_id)
        if sys.argv[1] == 'silent':
            return
        reports = (
            (HALL_UID, 770, b'\x08\x02\x10\x03'),  # Unknown Hall state.
            (HALL_UID, 770, b'\x08\x01\x10\x00'),  # Unreliable accuracy.
            (HALL_UID, 770, b'\x08\x01\x10\x04'),  # Unknown accuracy.
            (HALL_UID, 770, b'\x08\x01'),  # Missing required accuracy.
            (HALL_UID, 770, b'\x08\x01\x10\x03\x18\x00'),  # Unexpected field.
            ((13, 13), 770, b'\x08\x00\x10\x03'),  # Unrelated SUID.
            (HALL_UID, 769, b'\x08\x00\x10\x03'),  # Proximity event ID.
            (HALL_UID, 770, b'\x08\x01\x10\x03'),  # NEAR, high accuracy.
            (HALL_UID, 770, b'\x10\x03\x08\x00'),  # FAR with fields reversed.
        )
        for uid, event_id, payload in reports:
            self.send_event(uid, event_id, payload, node, port, transaction_id)
            time.sleep(0.05)


if __name__ == '__main__':
    multiprocessing.set_start_method('fork')
    if not upstream['supports_af_qipcrtr']():
        raise SystemExit(77)
    HallServer().start()
