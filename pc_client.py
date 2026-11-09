#!/usr/bin/env python3
"""
FF iOS Screen Streamer & Input Injector (PC Client)
Connects to jailbroken iOS device (iPhone 7, iOS 15.8.3) over USB (via iproxy) or LAN.
Streams screen via CADisplayLink JPEG stream and injects touch events via IOHIDEvent.
"""

import sys
import socket
import struct
import threading
import time
from typing import Optional

from PyQt6.QtCore import Qt, QThread, pyqtSignal, QPointF
from PyQt6.QtGui import QImage, QPixmap, QPainter, QColor, QFont, QKeyEvent, QMouseEvent
from PyQt6.QtWidgets import (
    QApplication,
    QMainWindow,
    QWidget,
    QLabel,
    QVBoxLayout,
    QHBoxLayout,
    QStatusBar,
)

# Target Device Parameters (iPhone 7 Resolution)
IPHONE7_WIDTH = 750
IPHONE7_HEIGHT = 1334

# Free Fire Landscape Defaults (1334 x 750)
FF_LANDSCAPE_WIDTH = 1334
FF_LANDSCAPE_HEIGHT = 750

# Default Virtual Button Layout (Landscape normalized coordinates 0.0 - 1.0)
JOYSTICK_CENTER_X = 0.18
JOYSTICK_CENTER_Y = 0.70
JOYSTICK_RADIUS = 0.08

JUMP_BUTTON_X = 0.90
JUMP_BUTTON_Y = 0.70


class StreamReceiverThread(QThread):
    """
    Background worker thread to continuously read JPEG frames from TCP socket.
    Protocol: 4 bytes uint32 length (<I, Little Endian), followed by JPEG data.
    """
    frame_received = pyqtSignal(bytes)
    connection_status = pyqtSignal(str, bool)

    def __init__(self, host: str = "127.0.0.1", port: int = 8080):
        super().__init__()
        self.host = host
        self.port = port
        self.running = True
        self.sock: Optional[socket.socket] = None
        self._send_lock = threading.Lock()

    def run(self):
        while self.running:
            try:
                self.connection_status.emit(f"Connecting to {self.host}:{self.port}...", False)
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                s.settimeout(5.0)
                s.connect((self.host, self.port))
                s.settimeout(None)
                
                with self._send_lock:
                    self.sock = s
                
                self.connection_status.emit(f"Connected to {self.host}:{self.port}", True)

                # Continuous receive loop
                while self.running:
                    # 1. Read 4 bytes length header (<I)
                    header = self._recv_exact(4)
                    if not header or len(header) < 4:
                        break
                    
                    frame_len = struct.unpack("<I", header)[0]
                    if frame_len == 0 or frame_len > 10 * 1024 * 1024:
                        # Safety check: frame shouldn't exceed 10MB
                        break

                    # 2. Read exactly frame_len bytes of JPEG data
                    frame_data = self._recv_exact(frame_len)
                    if not frame_data or len(frame_data) < frame_len:
                        break

                    self.frame_received.emit(frame_data)

            except Exception as e:
                self.connection_status.emit(f"Disconnected: {e}. Retrying in 2s...", False)
            finally:
                with self._send_lock:
                    if self.sock:
                        try:
                            self.sock.close()
                        except Exception:
                            pass
                        self.sock = None

            if self.running:
                time.sleep(2.0)

    def _recv_exact(self, length: int) -> Optional[bytes]:
        """Read exactly `length` bytes from the socket."""
        data = bytearray()
        while len(data) < length and self.running:
            try:
                packet = self.sock.recv(length - len(data))
                if not packet:
                    return None
                data.extend(packet)
            except Exception:
                return None
        return bytes(data)

    def send_command(self, cmd: str) -> bool:
        """Send a touch command string over the existing TCP socket."""
        with self._send_lock:
            if self.sock is not None:
                try:
                    payload = (cmd.strip() + "\n").encode("utf-8")
                    self.sock.sendall(payload)
                    return True
                except Exception:
                    return False
        return False

    def stop(self):
        self.running = False
        with self._send_lock:
            if self.sock:
                try:
                    self.sock.shutdown(socket.SHUT_RDWR)
                    self.sock.close()
                except Exception:
                    pass
                self.sock = None
        self.wait()


class VideoDisplayWidget(QLabel):
    """
    Interactive Video Display Widget that scales frames, handles mouse clicks & drags,
    and maps coordinates to the native iPhone resolution.
    """
    command_triggered = pyqtSignal(str)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.setMouseTracking(True)
        self.setStyleSheet("background-color: #0b0c10;")
        
        self.current_pixmap: Optional[QPixmap] = None
        self.is_right_dragging = False
        self.is_landscape = True

    def set_frame(self, pixmap: QPixmap):
        self.current_pixmap = pixmap
        # Determine orientation from incoming frame
        if pixmap.width() >= pixmap.height():
            self.is_landscape = True
        else:
            self.is_landscape = False
        self.update_display()

    def update_display(self):
        if self.current_pixmap and not self.current_pixmap.isNull():
            scaled = self.current_pixmap.scaled(
                self.size(),
                Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.FastTransformation,
            )
            self.setPixmap(scaled)
        else:
            self.setText("Waiting for video stream from iOS device...\nMake sure 'iproxy 8080 8080' is running.")

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self.update_display()

    def _map_to_iphone_coords(self, local_pos: QPointF) -> Optional[tuple[float, float]]:
        """
        Maps a mouse coordinate within the widget to the native iPhone resolution,
        taking into account aspect-ratio letterboxing / pillarboxing.
        """
        if not self.current_pixmap or self.current_pixmap.isNull():
            return None

        lbl_w = self.width()
        lbl_h = self.height()
        pm_w = self.current_pixmap.width()
        pm_h = self.current_pixmap.height()

        scale = min(lbl_w / pm_w, lbl_h / pm_h)
        disp_w = pm_w * scale
        disp_h = pm_h * scale
        offset_x = (lbl_w - disp_w) / 2.0
        offset_y = (lbl_h - disp_h) / 2.0

        # Check if click is inside the displayed video rectangle
        x = local_pos.x()
        y = local_pos.y()
        if not (offset_x <= x <= offset_x + disp_w and offset_y <= y <= offset_y + disp_h):
            return None

        # Normalized coordinates (0.0 to 1.0)
        norm_x = (x - offset_x) / disp_w
        norm_y = (y - offset_y) / disp_h

        # Scale to native target resolution (iPhone 7: 1334x750 in Landscape, 750x1334 in Portrait)
        if self.is_landscape:
            target_w = float(FF_LANDSCAPE_WIDTH)
            target_h = float(FF_LANDSCAPE_HEIGHT)
        else:
            target_w = float(IPHONE7_WIDTH)
            target_h = float(IPHONE7_HEIGHT)

        iphone_x = max(0.0, min(target_w, norm_x * target_w))
        iphone_y = max(0.0, min(target_h, norm_y * target_h))
        return iphone_x, iphone_y

    def mousePressEvent(self, event: QMouseEvent):
        coords = self._map_to_iphone_coords(event.position())
        if coords:
            ix, iy = coords
            if event.button() == Qt.MouseButton.LeftButton:
                # Left Click -> Fire button / Direct Tap
                cmd = f"{ix:.1f},{iy:.1f}"
                self.command_triggered.emit(cmd)
            elif event.button() == Qt.MouseButton.RightButton:
                # Right Click down -> Begin camera swipe
                self.is_right_dragging = True
                cmd = f"D,{ix:.1f},{iy:.1f}"
                self.command_triggered.emit(cmd)
        super().mousePressEvent(event)

    def mouseMoveEvent(self, event: QMouseEvent):
        if self.is_right_dragging:
            coords = self._map_to_iphone_coords(event.position())
            if coords:
                ix, iy = coords
                # Rapidly send commands to simulate camera drag
                cmd = f"{ix:.1f},{iy:.1f}"
                self.command_triggered.emit(cmd)
        super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event: QMouseEvent):
        if event.button() == Qt.MouseButton.RightButton:
            self.is_right_dragging = False
            coords = self._map_to_iphone_coords(event.position())
            if coords:
                ix, iy = coords
                cmd = f"U,{ix:.1f},{iy:.1f}"
                self.command_triggered.emit(cmd)
        super().mouseReleaseEvent(event)


class MainWindow(QMainWindow):
    """
    Main Application Window integrating video streaming, keyboard input mapping,
    and live status telemetry.
    """
    def __init__(self):
        super().__init__()
        self.setWindowTitle("FF iOS Controller & Streamer - iPhone 7 (iOS 15.8.3)")
        self.resize(1100, 680)

        # Telemetry State
        self.frame_count = 0
        self.fps = 0
        self.last_fps_time = time.time()
        self.last_command = "None"
        self.pressed_keys = set()

        # UI Setup
        self._init_ui()

        # Network Worker Thread
        self.receiver_thread = StreamReceiverThread(host="127.0.0.1", port=8080)
        self.receiver_thread.frame_received.connect(self.on_frame_received)
        self.receiver_thread.connection_status.connect(self.on_connection_status)
        self.receiver_thread.start()

    def _init_ui(self):
        central_widget = QWidget(self)
        self.setCentralWidget(central_widget)
        main_layout = QVBoxLayout(central_widget)
        main_layout.setContentsMargins(8, 8, 8, 8)
        main_layout.setSpacing(6)

        # Video Display
        self.video_widget = VideoDisplayWidget(self)
        self.video_widget.command_triggered.connect(self.send_touch_command)
        main_layout.addWidget(self.video_widget, stretch=1)

        # Status Bar
        self.status_bar = QStatusBar(self)
        self.setStatusBar(self.status_bar)
        
        self.conn_label = QLabel("Initializing...")
        self.fps_label = QLabel("FPS: 0")
        self.cmd_label = QLabel("Last Cmd: None")
        self.guide_label = QLabel("Controls: [LMB] Fire | [RMB + Drag] Camera | [WASD] Joystick | [Space] Jump")
        
        self.status_bar.addWidget(self.conn_label, 2)
        self.status_bar.addWidget(self.fps_label, 1)
        self.status_bar.addWidget(self.cmd_label, 2)
        self.status_bar.addPermanentWidget(self.guide_label)

    def on_frame_received(self, frame_bytes: bytes):
        """Decode JPEG and render on GUI thread."""
        img = QImage()
        if img.loadFromData(frame_bytes, "JPEG"):
            pixmap = QPixmap.fromImage(img)
            self.video_widget.set_frame(pixmap)

            # Calculate FPS
            self.frame_count += 1
            now = time.time()
            elapsed = now - self.last_fps_time
            if elapsed >= 1.0:
                self.fps = int(self.frame_count / elapsed)
                self.frame_count = 0
                self.last_fps_time = now
                self.fps_label.setText(f"FPS: {self.fps}")

    def on_connection_status(self, message: str, is_connected: bool):
        color = "#27ae60" if is_connected else "#e74c3c"
        self.conn_label.setText(f"<span style='color: {color}; font-weight: bold;'>● {message}</span>")

    def send_touch_command(self, cmd: str):
        """Send command string and update telemetry."""
        success = self.receiver_thread.send_command(cmd)
        if success:
            self.last_command = cmd
            self.cmd_label.setText(f"Last Cmd: {cmd}")

    def keyPressEvent(self, event: QKeyEvent):
        key = event.key()
        if event.isAutoRepeat():
            return super().keyPressEvent(event)

        self.pressed_keys.add(key)
        self._evaluate_keyboard_controls()
        super().keyPressEvent(event)

    def keyReleaseEvent(self, event: QKeyEvent):
        key = event.key()
        if event.isAutoRepeat():
            return super().keyReleaseEvent(event)

        if key in self.pressed_keys:
            self.pressed_keys.remove(key)
        self._evaluate_keyboard_controls()
        super().keyReleaseEvent(event)

    def _evaluate_keyboard_controls(self):
        """
        Maps WASD to the Virtual Joystick area and Space to Jump button.
        Coordinates are calculated based on Free Fire 1334x750 landscape canvas.
        """
        target_w = FF_LANDSCAPE_WIDTH if self.video_widget.is_landscape else IPHONE7_WIDTH
        target_h = FF_LANDSCAPE_HEIGHT if self.video_widget.is_landscape else IPHONE7_HEIGHT

        # Space Bar -> Jump
        if Qt.Key.Key_Space in self.pressed_keys:
            jump_x = target_w * JUMP_BUTTON_X
            jump_y = target_h * JUMP_BUTTON_Y
            self.send_touch_command(f"{jump_x:.1f},{jump_y:.1f}")

        # WASD -> Joystick Navigation
        dx = 0
        dy = 0
        if Qt.Key.Key_W in self.pressed_keys:
            dy -= 1
        if Qt.Key.Key_S in self.pressed_keys:
            dy += 1
        if Qt.Key.Key_A in self.pressed_keys:
            dx -= 1
        if Qt.Key.Key_D in self.pressed_keys:
            dx += 1

        if dx != 0 or dy != 0:
            cx = target_w * JOYSTICK_CENTER_X
            cy = target_h * JOYSTICK_CENTER_Y
            rx = target_w * JOYSTICK_RADIUS
            ry = target_h * JOYSTICK_RADIUS

            # Normalize diagonal vectors
            norm = (dx**2 + dy**2) ** 0.5
            move_x = cx + (dx / norm) * rx
            move_y = cy + (dy / norm) * ry
            self.send_touch_command(f"{move_x:.1f},{move_y:.1f}")

    def closeEvent(self, event):
        self.receiver_thread.stop()
        super().closeEvent(event)


def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    
    window = MainWindow()
    window.show()
    
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
