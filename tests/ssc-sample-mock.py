"""Extend the pinned upstream QRTR mock with gyroscope and no-data cases."""

import multiprocessing
import runpy
import sys
import time
from ctypes import c_char_p
from pathlib import Path

from ssc_server import ssc
from ssc_server import ssc_common_pb2 as common
from ssc_server import ssc_sensor_gyroscope_pb2 as gyro


upstream = runpy.run_path(str(Path(__file__).parent / 'ssc-server'))
GYRO_UID = (9, 9)
LIGHT_UID = (4, 4)


def response(uid, message_id, payload):
    result = common.SscClientResponse()
    result.uid.high, result.uid.low = uid
    body = result.response.add()
    body.msg_id = message_id
    body.timestamp = time.monotonic_ns()
    body.msg = payload.SerializeToString()
    return result.SerializeToString()


class Server(upstream['SSCMockingServer']):
    def _report(self, uid, message_id, payload, node, port, transaction_id):
        packet = ssc.SSC.generate_report_large_indication(
            response(uid, message_id, payload), transaction_id
        )
        return self._qrtr.qrtr_sendto(self.sock, node, port, c_char_p(packet), len(packet)) == 0

    def _sensor_measurement(self, uid_high, uid_low, node, port, transaction_id):
        uid = (uid_high, uid_low)
        if uid == LIGHT_UID and sys.argv[1] == 'silent-light':
            config = common.SscConfigResponse(sample_rate=5.0)
            self._report(uid, 768, config, node, port, transaction_id)
            return
        if uid != GYRO_UID:
            super()._sensor_measurement(uid_high, uid_low, node, port, transaction_id)
            return

        # Start with a non-finite axis, then send realistic finite three-axis frames.
        sample = gyro.SscGyroscopeResponse(velocity=[float('nan'), 0.0, 0.0], accuracy=3)
        self._report(uid, 1025, sample, node, port, transaction_id)
        while True:
            time.sleep(0.1)
            sample = gyro.SscGyroscopeResponse(velocity=[0.125, -0.25, 0.0], accuracy=3)
            if not self._report(uid, 1025, sample, node, port, transaction_id):
                return


if __name__ == '__main__':
    multiprocessing.set_start_method('fork')
    if not upstream['supports_af_qipcrtr']():
        raise SystemExit(77)
    Server().start()
