# this file is for the yolo implementation
# Update OS & install essentials, Update & install Docker:
sudo apt update && sudo apt upgrade -y
# install docker (official convenience script)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# log out and log back in (or reboot) so docker group is applied
# Pull and run Ultralytics ARM container (it includes models & runtime). This image contains Python and ultralytics tools tuned for ARM:
# pull the arm64 image
sudo docker pull ultralytics/ultralytics:latest-arm64

# run with access to camera and shared folder for outputs
sudo docker run -it --rm --device=/dev/video0:/dev/video0 --privileged \
  -v ~/yolo_output:/yolo_output \
  --ipc=host ultralytics/ultralytics:latest-arm64 /bin/bash
# Inside the container you’ll have Python. Create the script (below) as /yolo_output/detect_and_log.py and run:
python3 /yolo_output/detect_and_log.py --source 0 --out /yolo_output/detections.csv


# Option B if we had to use it:
#Update & install dependencies (some packages can be heavy):
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3-pip libatlas-base-dev libjpeg-dev build-essential
pip3 install --upgrade pip

#Install OpenCV and ultralytics. On Pi, opencv-python might be slow/large; if it fails, build OpenCV from source or install opencv-python-headless. Then install ultralytics:
pip3 install opencv-python-headless ultralytics
# the python script will be for logging:
python3 detect_and_log.py --source 0 --out detections.csv
detect_and_log.py:
#!/usr/bin/env python3
"""
detect_and_log.py
Simple YOLO (Ultralytics) realtime detection script for Raspberry Pi 4.

Usage:
  python3 detect_and_log.py --source 0 --out detections.csv --show  # webcam
  python3 detect_and_log.py --source video.mp4 --out detections.csv  # video file

Requirements (Docker method recommended):
  - ultralytics
  - opencv-python-headless (or opencv-python + GUI)
This script uses the yolov8n (nano) model for speed.
"""

import argparse
import csv
import time
from datetime import datetime
import cv2
from ultralytics import YOLO

def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument('--source', default=0, help='video source: 0 for /dev/video0 or path to video/file')
    p.add_argument('--out', default='detections.csv', help='CSV output file')
    p.add_argument('--show', action='store_true', help='Show video window (may slow down)')
    p.add_argument('--model', default='yolov8n.pt', help='Model to use (yolov8n.pt recommended)')
    p.add_argument('--conf', type=float, default=0.25, help='Confidence threshold')
    return p.parse_args()

def main():
    args = parse_args()

    # Open video source
    src = int(args.source) if str(args.source).isdigit() else args.source
    cap = cv2.VideoCapture(src)
    if not cap.isOpened():
        raise SystemExit(f'ERROR: cannot open source {args.source}')

    # Load YOLO model (will download yolov8n.pt if not present)
    model = YOLO(args.model)

    # Open CSV file for append (create if missing)
    csv_file = open(args.out, mode='a', newline='')
    csv_writer = csv.writer(csv_file)
    # Header if file is empty
    csv_file.seek(0)
    if csv_file.read(1) == '':
        csv_writer.writerow(['timestamp', 'class', 'confidence', 'x1', 'y1', 'x2', 'y2'])

    print("Starting detection. Press Ctrl-C to stop.")
    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                break

            # Run inference: use stream=True for lower memory usage
            # The .predict API accepts numpy frames as input; we use a single-frame call
            results = model.predict(source=[frame], stream=False, conf=args.conf, verbose=False)

            # results is a list; get first result
            if len(results) == 0:
                detections = []
            else:
                r = results[0]
                # r.boxes: BBoxes with .xyxy, .conf, .cls
                boxes = getattr(r, 'boxes', None)
                detections = []
                if boxes is not None:
                    for box in boxes:
                        # Each box: tensor-like object with .xyxy[0], .conf[0], .cls[0]
                        xyxy = box.xyxy[0].tolist()  # [x1,y1,x2,y2]
                        conf = float(box.conf[0])
                        clsid = int(box.cls[0])
                        clsname = model.names.get(clsid, str(clsid))
                        detections.append((clsname, conf, xyxy))

                        # write to CSV
                        ts = datetime.utcnow().isoformat() + "Z"
                        csv_writer.writerow([ts, clsname, f"{conf:.4f}", int(xyxy[0]), int(xyxy[1]), int(xyxy[2]), int(xyxy[3])])
                    csv_file.flush()

            # Optional: draw detections and show window
            if args.show:
                for (clsname, conf, xyxy) in detections:
                    x1,y1,x2,y2 = map(int, xyxy)
                    cv2.rectangle(frame, (x1,y1), (x2,y2), (0,255,0), 2)
                    label = f"{clsname} {conf:.2f}"
                    cv2.putText(frame, label, (x1, max(y1-6,0)), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0,255,0), 1)
                cv2.imshow('YOLO', frame)
                if cv2.waitKey(1) & 0xFF == ord('q'):
                    break

    except KeyboardInterrupt:
        print("Interrupted by user.")
    finally:
        cap.release()
        csv_file.close()
        if args.show:
            cv2.destroyAllWindows()
        print(f"Detections logged to {args.out}")

if __name__ == '__main__':
    main()
