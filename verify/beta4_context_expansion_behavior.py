#!/usr/bin/env python3

import inspect
import sys
from pathlib import Path

import torch


def main() -> int:
    source = Path(sys.argv[1]).resolve()
    sys.path.insert(0, str(source))

    from lada.restorationpipeline.mosaic_detector import Clip, Scene
    from lada.utils.scene_utils import crop_to_box_v3

    frame = torch.zeros((640, 640, 3), dtype=torch.uint8)
    mask = torch.zeros((640, 640, 1), dtype=torch.uint8)
    mask[100:400, 100:400] = 255
    box = (100, 100, 399, 399)

    scene = Scene("fixture.mp4", object())
    scene.add_frame(0, frame, mask, box)
    clip = Clip(scene, 256, "reflect", 0)

    _, _, baseline_box, _ = crop_to_box_v3(
        box, frame, mask, (256, 256), max_box_expansion_factor=1.0,
        border_size=0.06)
    expanded_box = clip.boxes[0]

    baseline_height = baseline_box[2] - baseline_box[0] + 1
    expanded_height = expanded_box[2] - expanded_box[0] + 1
    detection_height = box[2] - box[0] + 1
    assert expanded_height > baseline_height
    assert expanded_height <= int(detection_height * 1.25)
    assert clip.crop_shapes[0][:2] == (expanded_height, expanded_height)
    assert clip.frames[0].shape[:2] == (256, 256)
    assert clip.masks[0].shape[:2] == clip.frames[0].shape[:2]

    edge_scene = Scene("edge-fixture.mp4", object())
    edge_scene.add_frame(0, frame, mask, (0, 0, 299, 299))
    edge_clip = Clip(edge_scene, 256, "reflect", 1)
    top, left, bottom, right = edge_clip.boxes[0]
    assert top == 0 and left == 0
    assert 0 <= bottom < frame.shape[0]
    assert 0 <= right < frame.shape[1]

    parameters = tuple(inspect.signature(Clip.__init__).parameters)
    assert parameters == ("self", "scene", "size", "pad_mode", "id")

    print("PASS Beta4 context expansion behavior")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
