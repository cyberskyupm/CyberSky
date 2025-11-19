from time import sleep
from picamera2 import Picamera2
import cv2
import numpy as np

# --- Settings ---
CONF_THRESH = 0.4
NMS_THRESH = 0.4
IMG_SIZE = (320, 320)  # You can try (416, 416) for better accuracy but slower

CFG_PATH = "yolov3-tiny.cfg"
WEIGHTS_PATH = "yolov3-tiny.weights"
NAMES_PATH = "coco.names"

# --- Load class names ---
with open(NAMES_PATH, "r") as f:
    CLASSES = [line.strip() for line in f.readlines()]

# --- Load YOLOv3-tiny network ---
print("[*] Loading YOLOv3-tiny...")
net = cv2.dnn.readNetFromDarknet(CFG_PATH, WEIGHTS_PATH)
net.setPreferableBackend(cv2.dnn.DNN_BACKEND_OPENCV)
net.setPreferableTarget(cv2.dnn.DNN_TARGET_CPU)

layer_names = net.getLayerNames()
output_layers = [layer_names[i - 1] for i in net.getUnconnectedOutLayers().flatten()]
print("[+] YOLO loaded")

# --- Init Pi Camera for video ---
picam2 = Picamera2()

video_config = picam2.create_video_configuration({"size": (640, 480)})
picam2.configure(video_config)

print("[*] Starting camera...")
picam2.start()
sleep(2)  # warm-up

print("[*] Press ESC in the window to quit.")

while True:
    # Grab frame from camera (BGRA)
    frame = picam2.capture_array()

    # Convert BGRA → BGR
    frame = cv2.cvtColor(frame, cv2.COLOR_BGRA2BGR)

    height, width = frame.shape[:2]

    # YOLO blob
    blob = cv2.dnn.blobFromImage(frame, 1/255.0, IMG_SIZE, swapRB=True, crop=False)
    net.setInput(blob)
    outs = net.forward(output_layers)

    class_ids = []
    confidences = []
    boxes = []

    # Parse detections
    for out in outs:
        for detection in out:
            scores = detection[5:]
            class_id = int(np.argmax(scores))
            confidence = scores[class_id]
            if confidence > CONF_THRESH:
                center_x = int(detection[0] * width)
                center_y = int(detection[1] * height)
                w = int(detection[2] * width)
                h = int(detection[3] * height)
                x = int(center_x - w / 2)
                y = int(center_y - h / 2)
                boxes.append([x, y, w, h])
                confidences.append(float(confidence))
                class_ids.append(class_id)

    # Non-max suppression
    indexes = cv2.dnn.NMSBoxes(boxes, confidences, CONF_THRESH, NMS_THRESH)

    # Draw boxes
    if len(indexes) > 0:
        for i in indexes.flatten():
            x, y, w, h = boxes[i]
            label = CLASSES[class_ids[i]]
            conf = confidences[i]

            cv2.rectangle(frame, (x, y), (x + w, y + h), (0, 255, 0), 2)
            text = f"{label} {conf:.2f}"
            cv2.putText(frame, text, (x, y - 5),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 0), 1)

    # Show window
    cv2.imshow("YOLOv3-Tiny Live", frame)

    # ESC to quit
    key = cv2.waitKey(1) & 0xFF
    if key == 27:  # ESC
        break

# Cleanup
picam2.stop()
cv2.destroyAllWindows()
print("[*] Stopped.")
