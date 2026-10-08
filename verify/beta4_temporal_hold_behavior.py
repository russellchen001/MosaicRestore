#!/usr/bin/env python3

import importlib.util
import pathlib
import sys


def main():
    source_root = pathlib.Path(sys.argv[1])
    module_path = source_root / "lada/restorationpipeline/temporal_hold.py"
    spec = importlib.util.spec_from_file_location("temporal_hold", module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("unable to load temporal hold policy")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    hold = module.TemporalDetectorHold(frame_limit=2)
    assert [hold.on_miss(), hold.on_miss(), hold.on_miss()] == [True, True, False]
    assert hold.frames_since_detection == 2

    hold.on_detection()
    assert hold.frames_since_detection == 0
    assert hold.on_miss() is True

    try:
        module.TemporalDetectorHold(frame_limit=-1)
    except ValueError:
        pass
    else:
        raise AssertionError("negative hold windows must be rejected")

    sys.path.insert(0, str(source_root))
    import torch
    from lada.restorationpipeline.mosaic_detector import MosaicDetector, Scene

    frame = lambda value: torch.full((8, 8, 3), value, dtype=torch.uint8)
    mask = lambda value: torch.full((8, 8, 1), value, dtype=torch.uint8)

    scene = Scene("fixture.mp4", None)
    scene.add_frame(10, frame(10), mask(255), (1, 1, 6, 6))
    detector = MosaicDetector.__new__(MosaicDetector)

    detector._hold_recent_scenes([scene], 11, frame(11))
    detector._hold_recent_scenes([scene], 12, frame(12))
    detector._hold_recent_scenes([scene], 13, frame(13))

    assert scene.frame_end == 12
    assert len(scene.frames) == 3
    assert torch.equal(scene.masks[0], scene.masks[1])
    assert scene.masks[0].data_ptr() != scene.masks[1].data_ptr()

    scene.add_frame(13, frame(13), mask(192), (2, 2, 7, 7))
    assert scene.frame_end == 13
    assert scene.detector_hold.frames_since_detection == 0
    assert torch.equal(scene.masks[-1], mask(192))

    print("PASS Beta4 temporal detector hold integration behavior")


if __name__ == "__main__":
    main()
