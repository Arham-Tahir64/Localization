import pytest

from car_slam.common.calibrate import calibrate_camera


def test_calibration_rejects_too_few_valid_checkerboards(tmp_path):
    with pytest.raises(ValueError, match="at least eight"):
        calibrate_camera([], columns=9, rows=6, square_size=0.024)


def test_calibration_rejects_invalid_board_shape():
    with pytest.raises(ValueError, match="dimensions"):
        calibrate_camera([], columns=2, rows=6, square_size=0.024)
