# SAO (Simple Add-On) Driver Development Guide

This comprehensive guide explains how to develop and integrate SAO (Simple Add-On) drivers for the Disobey 2025 Badge firmware. It covers everything from the SAO standard to advanced GPIO utilization and software UART implementation.

## Table of Contents

1. [Introduction](#introduction)
2. [SAO Standard Overview](#sao-standard-overview)
3. [Hardware Requirements](#hardware-requirements)
4. [Basic SAO Driver Implementation](#basic-sao-driver-implementation)
5. [EEPROM Detection and Reading](#eeprom-detection-and-reading)
6. [Integration into Firmware](#integration-into-firmware)
7. [Advanced: GPIO Pin Utilization](#advanced-gpio-pin-utilization)
8. [Advanced: Software UART Implementation](#advanced-software-uart-implementation)
9. [Testing and Debugging](#testing-and-debugging)
10. [Complete Examples](#complete-examples)
11. [References](#references)

## Introduction

The SAO (Simple Add-On) or "Shitty Add-On" standard is a popular specification for creating modular hardware extensions for electronic badges. SAOs connect via a standardized 6-pin connector that provides power, ground, I2C communication, and two general-purpose GPIO pins.

This guide will teach you how to:
- Detect SAO devices via their EEPROM signature
- Read and parse SAO EEPROM data
- Control SAO hardware through I2C and GPIO
- Integrate SAO drivers into the Disobey Badge firmware
- Implement advanced features like software UART communication

## SAO Standard Overview

### SAO Connector Pinout

The standard SAO connector uses a 6-pin 2x3 header (2.54mm pitch) with the following pinout:

```
   1 2
   3 4
   5 6

Pin 1: VCC (3.3V)
Pin 2: GND
Pin 3: SDA (I2C Data)
Pin 4: SCL (I2C Clock)
Pin 5: GPIO1
Pin 6: GPIO2
```

### EEPROM Standard

SAOs must include an I2C EEPROM at address **0x50** (7-bit address) to be automatically detected. The EEPROM contains metadata about the SAO, including:

- Name and description
- Manufacturer information
- Driver requirements
- GPIO pin functions
- Additional configuration data

The EEPROM format typically follows the SAO v1.69bis standard documented at badge.team.

### Key Features

- **Universal Detection**: All SAOs can be detected via I2C scan for address 0x50
- **Self-Describing**: EEPROM contains all information needed to use the SAO
- **Hot-Pluggable**: Can be connected/disconnected without damage (with proper protection)
- **Simple Interface**: Uses I2C and/or GPIO for communication
- **Low Power**: Designed for battery-powered badge operation

## Hardware Requirements

### Badge Hardware Configuration

The Disobey 2025 Badge is based on the ESP32-S3 microcontroller, which provides:

- Multiple I2C bus support
- Software-configurable I2C on any GPIO pins
- Hardware I2C peripherals (2 available)
- 3.3V GPIO compatible with SAO standard

### Available GPIO Pins

Based on the badge hardware configuration in `HARDWARE.md`, the following pins are **currently used**:

**Display (SPI)**:
- GPIO 4: SPI SCK
- GPIO 5: SPI MOSI
- GPIO 6: Display CS
- GPIO 7: Display RST
- GPIO 15: Display DC
- GPIO 16: SPI MISO (unused)
- GPIO 19: Backlight

**Buttons**:
- GPIO 1, 2, 11, 12, 13, 14, 21, 38, 45

**LEDs**:
- GPIO 17: LED Enable
- GPIO 18: LED Data

### Recommended SAO Pins

The following pins are **available** for SAO connector use:

**Recommended Primary SAO Connector** (good electrical characteristics):
- **SDA**: GPIO 8 or GPIO 9
- **SCL**: GPIO 10 or GPIO 3
- **GPIO1**: GPIO 39 or GPIO 40
- **GPIO2**: GPIO 41 or GPIO 42

**Alternative Options**:
- GPIO 22-31 (if available on your badge variant)
- GPIO 43, 44 (with careful consideration of strapping)
- GPIO 46, 47, 48 (check for USB conflicts)

**Important Notes**:
- Verify pin availability with your specific badge schematic
- Some pins may have internal pull-ups/pull-downs
- Strapping pins (0, 3, 45, 46) should be used cautiously
- Check for conflicts with USB pins (19, 20) if applicable

## Basic SAO Driver Implementation

### Step 1: Create the Driver Module

Create a new file: `/frozen_firmware/modules/drivers/sao_base.py`

```python
"""
SAO (Simple Add-On) Base Driver

Provides basic functionality for detecting and communicating with SAO devices.
"""

from machine import Pin, I2C
import time

# SAO EEPROM Standard Address
SAO_EEPROM_ADDR = 0x50  # 7-bit I2C address

# Default I2C Configuration
DEFAULT_SDA_PIN = 8
DEFAULT_SCL_PIN = 10
DEFAULT_I2C_FREQ = 100000  # 100kHz standard I2C


class SAOError(Exception):
    """Base exception for SAO-related errors"""
    pass


class SAONotFoundError(SAOError):
    """Raised when no SAO is detected"""
    pass


class SAOCommunicationError(SAOError):
    """Raised when communication with SAO fails"""
    pass


class SAOBase:
    """
    Base class for SAO drivers.
    
    Provides I2C communication and EEPROM reading functionality.
    """
    
    def __init__(self, i2c=None, sda_pin=DEFAULT_SDA_PIN, scl_pin=DEFAULT_SCL_PIN,
                 freq=DEFAULT_I2C_FREQ, gpio1_pin=None, gpio2_pin=None):
        """
        Initialize SAO driver.
        
        Args:
            i2c: Existing I2C object (optional, will create new if None)
            sda_pin: GPIO pin for I2C SDA (default: 8)
            scl_pin: GPIO pin for I2C SCL (default: 10)
            freq: I2C frequency in Hz (default: 100000)
            gpio1_pin: GPIO pin number for SAO GPIO1 (optional)
            gpio2_pin: GPIO pin number for SAO GPIO2 (optional)
        """
        # Initialize I2C bus
        if i2c is None:
            self.i2c = I2C(0, scl=Pin(scl_pin), sda=Pin(sda_pin), freq=freq)
        else:
            self.i2c = i2c
        
        # Store pin numbers for reference
        self.sda_pin = sda_pin
        self.scl_pin = scl_pin
        
        # Initialize GPIO pins if provided
        self.gpio1 = Pin(gpio1_pin, Pin.IN) if gpio1_pin is not None else None
        self.gpio2 = Pin(gpio2_pin, Pin.IN) if gpio2_pin is not None else None
        
        # SAO information (will be populated from EEPROM)
        self.name = "Unknown SAO"
        self.description = ""
        self.manufacturer = ""
        self.eeprom_data = None
    
    def detect(self):
        """
        Detect if an SAO is present by scanning for EEPROM at 0x50.
        
        Returns:
            bool: True if SAO detected, False otherwise
        """
        try:
            devices = self.i2c.scan()
            return SAO_EEPROM_ADDR in devices
        except Exception as e:
            print(f"SAO detection error: {e}")
            return False
    
    def read_eeprom(self, addr, length):
        """
        Read data from SAO EEPROM.
        
        Args:
            addr: EEPROM address to read from (0-255 for most EEPROMs)
            length: Number of bytes to read
            
        Returns:
            bytes: Data read from EEPROM
            
        Raises:
            SAOCommunicationError: If read fails
        """
        try:
            # Write address to read from
            self.i2c.writeto(SAO_EEPROM_ADDR, bytes([addr]))
            time.sleep_ms(5)  # Small delay for EEPROM
            
            # Read data
            data = self.i2c.readfrom(SAO_EEPROM_ADDR, length)
            return data
        except Exception as e:
            raise SAOCommunicationError(f"EEPROM read failed: {e}")
    
    def read_eeprom_block(self, start_addr=0, max_length=256):
        """
        Read a block of data from EEPROM until null terminator or max length.
        
        Args:
            start_addr: Starting address (default: 0)
            max_length: Maximum bytes to read (default: 256)
            
        Returns:
            bytes: Data read from EEPROM
        """
        data = bytearray()
        addr = start_addr
        
        while len(data) < max_length:
            byte = self.read_eeprom(addr, 1)
            if byte[0] == 0:  # Null terminator
                break
            data.extend(byte)
            addr += 1
        
        return bytes(data)
    
    def parse_eeprom_info(self):
        """
        Parse basic SAO information from EEPROM.
        
        This is a simple parser for demonstration. Real SAOs may use
        different formats (JSON, binary structures, etc.)
        
        Returns:
            dict: Parsed SAO information
        """
        try:
            # Read first 256 bytes
            self.eeprom_data = self.read_eeprom_block(0, 256)
            
            # Try to parse as null-terminated strings
            # Format: name\0description\0manufacturer\0
            parts = self.eeprom_data.split(b'\0')
            
            info = {
                'raw_data': self.eeprom_data,
                'name': parts[0].decode('utf-8', 'ignore') if len(parts) > 0 else 'Unknown',
                'description': parts[1].decode('utf-8', 'ignore') if len(parts) > 1 else '',
                'manufacturer': parts[2].decode('utf-8', 'ignore') if len(parts) > 2 else '',
            }
            
            self.name = info['name']
            self.description = info['description']
            self.manufacturer = info['manufacturer']
            
            return info
            
        except Exception as e:
            print(f"EEPROM parse error: {e}")
            return {
                'name': 'Unknown',
                'description': 'Parse error',
                'manufacturer': '',
                'error': str(e)
            }
    
    def configure_gpio(self, pin_num, mode, pull=None):
        """
        Configure a GPIO pin.
        
        Args:
            pin_num: 1 for GPIO1, 2 for GPIO2
            mode: Pin.IN, Pin.OUT, etc.
            pull: Pin.PULL_UP, Pin.PULL_DOWN, or None
        """
        if pin_num == 1 and self.gpio1 is not None:
            pin = self.gpio1.init(mode=mode, pull=pull)
        elif pin_num == 2 and self.gpio2 is not None:
            pin = self.gpio2.init(mode=mode, pull=pull)
        else:
            raise ValueError(f"Invalid GPIO pin number: {pin_num}")
    
    def gpio_write(self, pin_num, value):
        """Write digital value to GPIO pin."""
        if pin_num == 1 and self.gpio1 is not None:
            self.gpio1.value(value)
        elif pin_num == 2 and self.gpio2 is not None:
            self.gpio2.value(value)
        else:
            raise ValueError(f"Invalid GPIO pin number: {pin_num}")
    
    def gpio_read(self, pin_num):
        """Read digital value from GPIO pin."""
        if pin_num == 1 and self.gpio1 is not None:
            return self.gpio1.value()
        elif pin_num == 2 and self.gpio2 is not None:
            return self.gpio2.value()
        else:
            raise ValueError(f"Invalid GPIO pin number: {pin_num}")
    
    def __str__(self):
        return f"SAO: {self.name} by {self.manufacturer}"
```

### Step 2: Test Basic Detection

Create a test script: `/firmware/test_sao.py`

```python
"""
Test script for SAO detection.

Usage:
    >>> import test_sao
    >>> test_sao.test_detection()
"""

from drivers.sao_base import SAOBase, SAONotFoundError

def test_detection():
    """Test SAO detection on default pins."""
    print("Initializing SAO driver...")
    sao = SAOBase(sda_pin=8, scl_pin=10)
    
    print("Scanning I2C bus...")
    devices = sao.i2c.scan()
    print(f"Found I2C devices at addresses: {[hex(addr) for addr in devices]}")
    
    if sao.detect():
        print("✓ SAO detected at address 0x50!")
        
        print("\nReading EEPROM...")
        try:
            info = sao.parse_eeprom_info()
            print(f"Name: {info['name']}")
            print(f"Description: {info['description']}")
            print(f"Manufacturer: {info['manufacturer']}")
            print(f"\nRaw EEPROM data (first 64 bytes):")
            print(info['raw_data'][:64])
        except Exception as e:
            print(f"Error reading EEPROM: {e}")
    else:
        print("✗ No SAO detected at address 0x50")
        print("Make sure:")
        print("  1. SAO is properly connected")
        print("  2. I2C pins are correct (SDA=8, SCL=10)")
        print("  3. SAO has EEPROM at address 0x50")

if __name__ == "__main__":
    test_detection()
```

## EEPROM Detection and Reading

### Understanding EEPROM Addressing

SAO EEPROMs typically use:
- **I2C Address**: 0x50 (7-bit addressing)
- **Memory Organization**: 256 bytes to 8 KB typical
- **Page Size**: 16-32 bytes for writing
- **Access Time**: ~5ms for write operations

### Reading EEPROM Data

#### Sequential Read

```python
def read_sequential(self, start_addr, length):
    """
    Read sequential bytes from EEPROM.
    
    More efficient than individual reads.
    """
    # Set read address
    self.i2c.writeto(SAO_EEPROM_ADDR, bytes([start_addr]))
    time.sleep_ms(5)
    
    # Read all bytes at once
    data = self.i2c.readfrom(SAO_EEPROM_ADDR, length)
    return data
```

#### Random Access Read

```python
def read_random(self, addr):
    """Read single byte at specific address."""
    self.i2c.writeto(SAO_EEPROM_ADDR, bytes([addr]))
    time.sleep_ms(1)
    return self.i2c.readfrom(SAO_EEPROM_ADDR, 1)[0]
```

### Writing to EEPROM (Optional)

**Warning**: Writing to EEPROM is typically not needed for SAO operation, as EEPROMs come pre-programmed. However, for development:

```python
def write_eeprom_byte(self, addr, value):
    """
    Write single byte to EEPROM.
    
    Warning: EEPROMs have limited write cycles (~100k-1M writes).
    Only use during development/programming.
    """
    try:
        # Write address and data
        self.i2c.writeto(SAO_EEPROM_ADDR, bytes([addr, value]))
        time.sleep_ms(10)  # Wait for write cycle to complete
        return True
    except Exception as e:
        print(f"EEPROM write failed: {e}")
        return False
```

### Parsing SAO EEPROM Data

Different SAOs may use different EEPROM formats. Here are common patterns:

#### Simple String Format

```python
def parse_simple_strings(data):
    """
    Parse null-terminated strings.
    Format: name\0description\0url\0
    """
    strings = data.split(b'\0')
    return {
        'name': strings[0].decode('utf-8', 'ignore'),
        'description': strings[1].decode('utf-8', 'ignore') if len(strings) > 1 else '',
        'url': strings[2].decode('utf-8', 'ignore') if len(strings) > 2 else '',
    }
```

#### JSON Format

```python
import json

def parse_json_format(data):
    """
    Parse JSON-formatted EEPROM data.
    Format: {"name": "...", "version": "...", ...}
    """
    try:
        # Find JSON boundaries
        json_str = data.decode('utf-8', 'ignore')
        info = json.loads(json_str)
        return info
    except Exception as e:
        print(f"JSON parse error: {e}")
        return {}
```

#### Binary Structure Format

```python
import struct

def parse_binary_structure(data):
    """
    Parse binary structure format.
    Example structure:
        - 4 bytes: magic number
        - 2 bytes: version
        - 16 bytes: name (null-padded)
        - 64 bytes: description (null-padded)
    """
    if len(data) < 86:
        return {}
    
    magic, version = struct.unpack('<IH', data[0:6])
    name = data[6:22].decode('utf-8', 'ignore').rstrip('\0')
    description = data[22:86].decode('utf-8', 'ignore').rstrip('\0')
    
    return {
        'magic': hex(magic),
        'version': version,
        'name': name,
        'description': description,
    }
```

## Integration into Firmware

### Step 1: Add Driver to Frozen Firmware

For production use, move your driver to frozen firmware:

1. Place driver in `/frozen_firmware/modules/drivers/sao_base.py`
2. Update `/frozen_firmware/frozen_manifest.py`:

```python
# In frozen_manifest.py, add:
freeze("$(PORT_DIR)/modules/drivers", "sao_base.py")
```

3. Rebuild firmware:

```bash
make build_firmware
```

### Step 2: Create SAO Manager Module

Create `/frozen_firmware/modules/bdg/sao_manager.py`:

```python
"""
SAO Manager for Badge

Manages SAO detection, initialization, and lifecycle.
"""

from drivers.sao_base import SAOBase, SAONotFoundError
import asyncio


class SAOManager:
    """Manages multiple SAO connectors on the badge."""
    
    def __init__(self):
        self.saos = {}  # connector_id -> SAO instance
        self.active_saos = []
    
    def register_connector(self, connector_id, sda_pin, scl_pin, 
                          gpio1_pin=None, gpio2_pin=None):
        """
        Register an SAO connector.
        
        Args:
            connector_id: Unique identifier (e.g., "SAO1", "SAO2")
            sda_pin, scl_pin: I2C pin numbers
            gpio1_pin, gpio2_pin: GPIO pin numbers (optional)
        """
        sao = SAOBase(sda_pin=sda_pin, scl_pin=scl_pin,
                     gpio1_pin=gpio1_pin, gpio2_pin=gpio2_pin)
        self.saos[connector_id] = sao
        return sao
    
    def scan_all(self):
        """
        Scan all registered connectors for SAOs.
        
        Returns:
            dict: {connector_id: SAO info or None}
        """
        results = {}
        for conn_id, sao in self.saos.items():
            if sao.detect():
                try:
                    info = sao.parse_eeprom_info()
                    results[conn_id] = info
                    self.active_saos.append((conn_id, sao))
                except Exception as e:
                    results[conn_id] = {'error': str(e)}
            else:
                results[conn_id] = None
        return results
    
    def get_sao(self, connector_id):
        """Get SAO instance for a specific connector."""
        return self.saos.get(connector_id)
    
    async def monitor_saos(self, interval_ms=5000):
        """
        Continuously monitor for SAO connection/disconnection.
        
        Args:
            interval_ms: Scan interval in milliseconds
        """
        while True:
            results = self.scan_all()
            for conn_id, info in results.items():
                if info:
                    print(f"{conn_id}: {info['name']}")
            await asyncio.sleep_ms(interval_ms)


# Global SAO manager instance
sao_manager = SAOManager()


def init_sao_system():
    """Initialize SAO system with badge's connector configuration."""
    # Register SAO connector(s) based on badge hardware
    # Example: badge has one SAO connector
    sao_manager.register_connector(
        connector_id="SAO1",
        sda_pin=8,
        scl_pin=10,
        gpio1_pin=39,
        gpio2_pin=40
    )
    
    # Scan for connected SAOs
    results = sao_manager.scan_all()
    print("SAO scan results:", results)
    
    return sao_manager
```

### Step 3: Initialize in Main

Update `/frozen_firmware/modules/main.py` to initialize SAO system:

```python
# In main.py, add:
from bdg.sao_manager import init_sao_system

def init():
    """Initialize badge systems."""
    # ... existing initialization code ...
    
    # Initialize SAO system
    try:
        sao_mgr = init_sao_system()
        print("SAO system initialized")
    except Exception as e:
        print(f"SAO init error: {e}")
    
    # ... rest of initialization ...
```

### Step 4: Create SAO Info Screen

Create `/frozen_firmware/modules/bdg/screens/sao_screen.py`:

```python
"""
SAO Information Screen

Displays information about connected SAOs.
"""

import hardware_setup as hardware_setup
from hardware_setup import BtnConfig

from gui.core.ugui import Screen, ssd
from gui.widgets import Label, Button
from gui.core.writer import CWriter
from gui.fonts import font10, arial35
from gui.core.colors import *

from bdg.sao_manager import sao_manager


class SAOScreen(Screen):
    """Screen to display SAO information."""
    
    def __init__(self):
        super().__init__()
        self.setup_ui()
        self.update_display()
    
    def setup_ui(self):
        """Create UI elements."""
        wri = CWriter(ssd, font10, GREEN, BLACK)
        wri_title = CWriter(ssd, arial35, WHITE, BLACK)
        
        # Title
        Label(wri_title, 10, 10, "SAO Info")
        
        # SAO information labels
        self.labels = []
        y = 60
        for i in range(4):  # Space for up to 4 SAOs or messages
            label = Label(wri, y, 10, 300)
            self.labels.append(label)
            y += 20
        
        # Refresh button
        Button(wri, 140, 10, text="Refresh", callback=self.refresh)
        
        # Back button
        Button(wri, 140, 120, text="Back", callback=lambda b: Screen.back())
    
    def update_display(self):
        """Update SAO information display."""
        results = sao_manager.scan_all()
        
        if not results or all(v is None for v in results.values()):
            self.labels[0].value("No SAOs detected")
            for i in range(1, len(self.labels)):
                self.labels[i].value("")
        else:
            idx = 0
            for conn_id, info in results.items():
                if info and idx < len(self.labels):
                    if 'error' in info:
                        self.labels[idx].value(f"{conn_id}: Error")
                    else:
                        self.labels[idx].value(f"{conn_id}: {info['name']}")
                    idx += 1
            
            # Clear remaining labels
            for i in range(idx, len(self.labels)):
                self.labels[i].value("")
    
    def refresh(self, btn):
        """Refresh SAO detection."""
        self.labels[0].value("Scanning...")
        self.update_display()
```

### Step 5: Add to Main Menu

Update your main menu to include the SAO screen:

```python
# In your menu screen setup
from bdg.screens.sao_screen import SAOScreen

# Add button to launch SAO screen
Button(wri, row, col, text="SAO Info", 
       callback=lambda b: Screen.change(SAOScreen))
```

## Advanced: GPIO Pin Utilization

SAO GPIO pins can be used for various purposes beyond I2C communication. This section covers advanced GPIO usage patterns.

### Digital Output Control

Use GPIO pins to control LEDs, buzzers, or other digital outputs on the SAO:

```python
class SAOWithLED(SAOBase):
    """SAO driver with LED control on GPIO1."""
    
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        # Configure GPIO1 as output
        if self.gpio1:
            self.gpio1.init(mode=Pin.OUT, value=0)
    
    def led_on(self):
        """Turn LED on."""
        if self.gpio1:
            self.gpio1.value(1)
    
    def led_off(self):
        """Turn LED off."""
        if self.gpio1:
            self.gpio1.value(0)
    
    def led_toggle(self):
        """Toggle LED state."""
        if self.gpio1:
            self.gpio1.value(not self.gpio1.value())
    
    async def led_blink(self, interval_ms=500, count=5):
        """Blink LED a number of times."""
        for _ in range(count):
            self.led_on()
            await asyncio.sleep_ms(interval_ms)
            self.led_off()
            await asyncio.sleep_ms(interval_ms)
```

### Digital Input Reading

Read button presses or sensor states from SAO GPIO pins:

```python
class SAOWithButton(SAOBase):
    """SAO driver with button input on GPIO1."""
    
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        # Configure GPIO1 as input with pull-up
        if self.gpio1:
            self.gpio1.init(mode=Pin.IN, pull=Pin.PULL_UP)
    
    def is_button_pressed(self):
        """Check if button is pressed (active low)."""
        if self.gpio1:
            return self.gpio1.value() == 0
        return False
    
    async def wait_for_button(self, timeout_ms=5000):
        """
        Wait for button press with timeout.
        
        Returns:
            bool: True if button pressed, False if timeout
        """
        start = time.ticks_ms()
        while time.ticks_diff(time.ticks_ms(), start) < timeout_ms:
            if self.is_button_pressed():
                # Debounce
                await asyncio.sleep_ms(50)
                if self.is_button_pressed():
                    return True
            await asyncio.sleep_ms(10)
        return False
    
    async def monitor_button(self, callback):
        """
        Continuously monitor button and call callback on press.
        
        Args:
            callback: Async function to call when button pressed
        """
        last_state = False
        while True:
            current_state = self.is_button_pressed()
            
            # Detect falling edge (button press)
            if current_state and not last_state:
                await asyncio.sleep_ms(50)  # Debounce
                if self.is_button_pressed():
                    await callback()
            
            last_state = current_state
            await asyncio.sleep_ms(10)
```

### PWM Control

Use PWM on GPIO pins for dimming LEDs or controlling servos:

```python
from machine import PWM

class SAOWithPWM(SAOBase):
    """SAO driver with PWM control on GPIO pins."""
    
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.pwm1 = None
        self.pwm2 = None
    
    def init_pwm(self, pin_num=1, freq=1000):
        """
        Initialize PWM on a GPIO pin.
        
        Args:
            pin_num: 1 for GPIO1, 2 for GPIO2
            freq: PWM frequency in Hz (default: 1kHz)
        """
        if pin_num == 1 and self.gpio1:
            self.pwm1 = PWM(self.gpio1, freq=freq, duty=0)
            return self.pwm1
        elif pin_num == 2 and self.gpio2:
            self.pwm2 = PWM(self.gpio2, freq=freq, duty=0)
            return self.pwm2
        else:
            raise ValueError(f"Invalid pin number: {pin_num}")
    
    def set_duty(self, pin_num, duty_percent):
        """
        Set PWM duty cycle.
        
        Args:
            pin_num: 1 or 2
            duty_percent: Duty cycle 0-100
        """
        duty = int((duty_percent / 100) * 1023)
        duty = max(0, min(1023, duty))
        
        if pin_num == 1 and self.pwm1:
            self.pwm1.duty(duty)
        elif pin_num == 2 and self.pwm2:
            self.pwm2.duty(duty)
    
    async def fade_led(self, pin_num=1, duration_ms=1000):
        """Fade LED in and out."""
        steps = 50
        delay = duration_ms // (steps * 2)
        
        # Fade in
        for i in range(steps + 1):
            self.set_duty(pin_num, (i / steps) * 100)
            await asyncio.sleep_ms(delay)
        
        # Fade out
        for i in range(steps, -1, -1):
            self.set_duty(pin_num, (i / steps) * 100)
            await asyncio.sleep_ms(delay)
```

### Interrupt-Based Input

Use interrupts for efficient button/sensor monitoring:

```python
class SAOWithInterrupt(SAOBase):
    """SAO driver with interrupt-based input."""
    
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.interrupt_flag = False
        self.interrupt_callback = None
        
        # Configure interrupt
        if self.gpio1:
            self.gpio1.init(mode=Pin.IN, pull=Pin.PULL_UP)
            self.gpio1.irq(trigger=Pin.IRQ_FALLING, handler=self._irq_handler)
    
    def _irq_handler(self, pin):
        """Internal interrupt handler."""
        self.interrupt_flag = True
        if self.interrupt_callback:
            self.interrupt_callback(pin)
    
    def set_interrupt_callback(self, callback):
        """
        Set callback for interrupt events.
        
        Args:
            callback: Function to call on interrupt (runs in IRQ context)
        """
        self.interrupt_callback = callback
    
    async def wait_for_interrupt(self, timeout_ms=5000):
        """
        Wait for interrupt event.
        
        Returns:
            bool: True if interrupt occurred, False if timeout
        """
        self.interrupt_flag = False
        start = time.ticks_ms()
        
        while time.ticks_diff(time.ticks_ms(), start) < timeout_ms:
            if self.interrupt_flag:
                self.interrupt_flag = False
                return True
            await asyncio.sleep_ms(10)
        
        return False
```

## Advanced: Software UART Implementation

Software UART enables serial communication over the SAO GPIO pins, allowing protocols like:
- Simple text communication
- Binary protocols
- Sensor data streaming
- Custom protocols

### Basic Software UART

```python
"""
Software UART implementation for SAO GPIO pins.

Implements basic UART communication without hardware UART peripheral.
"""

import time
from machine import Pin
import asyncio


class SoftUART:
    """
    Software UART implementation.
    
    Supports configurable baud rates and 8N1 format (8 data bits, no parity, 1 stop bit).
    """
    
    def __init__(self, tx_pin=None, rx_pin=None, baudrate=9600):
        """
        Initialize software UART.
        
        Args:
            tx_pin: Pin object or pin number for TX
            rx_pin: Pin object or pin number for RX
            baudrate: Baud rate in bits per second (default: 9600)
        """
        # Initialize pins
        if tx_pin is not None:
            self.tx = tx_pin if isinstance(tx_pin, Pin) else Pin(tx_pin, Pin.OUT)
            self.tx.value(1)  # Idle high
        else:
            self.tx = None
        
        if rx_pin is not None:
            self.rx = rx_pin if isinstance(rx_pin, Pin) else Pin(rx_pin, Pin.IN, Pin.PULL_UP)
        else:
            self.rx = None
        
        # Calculate bit timing (in microseconds)
        self.bit_time_us = 1000000 // baudrate
        self.baudrate = baudrate
        
        # Reception buffer
        self.rx_buffer = bytearray()
        self.receiving = False
    
    def write_byte(self, byte):
        """
        Write a single byte (blocking).
        
        Args:
            byte: Byte value to write (0-255)
        """
        if not self.tx:
            raise RuntimeError("TX pin not configured")
        
        # Disable interrupts for timing accuracy
        # Start bit (low)
        self.tx.value(0)
        time.sleep_us(self.bit_time_us)
        
        # Data bits (LSB first)
        for i in range(8):
            bit = (byte >> i) & 1
            self.tx.value(bit)
            time.sleep_us(self.bit_time_us)
        
        # Stop bit (high)
        self.tx.value(1)
        time.sleep_us(self.bit_time_us)
    
    def write(self, data):
        """
        Write bytes or string.
        
        Args:
            data: bytes, bytearray, or string to write
        """
        if isinstance(data, str):
            data = data.encode('utf-8')
        
        for byte in data:
            self.write_byte(byte)
    
    def read_byte(self, timeout_us=100000):
        """
        Read a single byte (blocking with timeout).
        
        Args:
            timeout_us: Timeout in microseconds (default: 100ms)
            
        Returns:
            int: Byte value (0-255) or None if timeout
        """
        if not self.rx:
            raise RuntimeError("RX pin not configured")
        
        # Wait for start bit (high to low transition)
        start_time = time.ticks_us()
        while self.rx.value() == 1:
            if time.ticks_diff(time.ticks_us(), start_time) > timeout_us:
                return None
        
        # Wait for middle of start bit
        time.sleep_us(self.bit_time_us // 2)
        
        # Verify start bit
        if self.rx.value() != 0:
            return None
        
        # Read data bits
        byte = 0
        for i in range(8):
            time.sleep_us(self.bit_time_us)
            if self.rx.value():
                byte |= (1 << i)
        
        # Read stop bit
        time.sleep_us(self.bit_time_us)
        if self.rx.value() != 1:
            # Framing error
            return None
        
        return byte
    
    async def read_byte_async(self, timeout_ms=100):
        """
        Async version of read_byte.
        
        Args:
            timeout_ms: Timeout in milliseconds
            
        Returns:
            int: Byte value or None if timeout
        """
        start_time = time.ticks_ms()
        
        # Wait for start bit
        while self.rx and self.rx.value() == 1:
            if time.ticks_diff(time.ticks_ms(), start_time) > timeout_ms:
                return None
            await asyncio.sleep_ms(1)
        
        # Read byte synchronously (fast operation)
        return self.read_byte(timeout_us=self.bit_time_us * 12)
    
    def available(self):
        """Check if RX line has incoming data (start bit low)."""
        return self.rx and self.rx.value() == 0
    
    async def read_line_async(self, timeout_ms=1000):
        """
        Read line until newline or timeout.
        
        Args:
            timeout_ms: Timeout in milliseconds
            
        Returns:
            str: Received line or None if timeout
        """
        line = bytearray()
        start_time = time.ticks_ms()
        
        while time.ticks_diff(time.ticks_ms(), start_time) < timeout_ms:
            byte = await self.read_byte_async(timeout_ms=10)
            if byte is not None:
                if byte == ord('\n'):
                    break
                elif byte == ord('\r'):
                    continue
                else:
                    line.append(byte)
                start_time = time.ticks_ms()  # Reset timeout on data
            else:
                await asyncio.sleep_ms(1)
        
        if len(line) > 0:
            return line.decode('utf-8', 'ignore')
        return None


class SAOWithUART(SAOBase):
    """SAO driver with software UART communication."""
    
    def __init__(self, baudrate=9600, **kwargs):
        """
        Initialize SAO with UART.
        
        Args:
            baudrate: UART baud rate (default: 9600)
            **kwargs: Arguments for SAOBase
        """
        super().__init__(**kwargs)
        
        # Create software UART using GPIO pins
        # GPIO1 = TX, GPIO2 = RX
        self.uart = SoftUART(
            tx_pin=self.gpio1,
            rx_pin=self.gpio2,
            baudrate=baudrate
        )
    
    def uart_write(self, data):
        """Write data over UART."""
        self.uart.write(data)
    
    async def uart_read_line(self, timeout_ms=1000):
        """Read line from UART."""
        return await self.uart.read_line_async(timeout_ms)
    
    async def uart_command_response(self, command, timeout_ms=500):
        """
        Send command and wait for response.
        
        Args:
            command: Command string to send
            timeout_ms: Response timeout
            
        Returns:
            str: Response or None if timeout
        """
        # Send command
        self.uart_write(command + '\n')
        
        # Wait for response
        response = await self.uart_read_line(timeout_ms)
        return response
```

### UART Communication Patterns

#### Command-Response Protocol

```python
class SAOCommandDevice(SAOWithUART):
    """SAO device using command-response protocol."""
    
    async def send_command(self, cmd, *args):
        """
        Send command with arguments and wait for response.
        
        Format: CMD arg1 arg2\n
        Response: OK result\n or ERROR message\n
        """
        # Build command string
        cmd_str = cmd
        if args:
            cmd_str += ' ' + ' '.join(str(a) for a in args)
        
        # Send and wait for response
        response = await self.uart_command_response(cmd_str)
        
        if response:
            parts = response.split(' ', 1)
            status = parts[0]
            value = parts[1] if len(parts) > 1 else ''
            
            if status == 'OK':
                return True, value
            else:
                return False, value
        
        return False, 'Timeout'
    
    async def read_sensor(self):
        """Read sensor value via UART command."""
        success, value = await self.send_command('READ')
        if success:
            try:
                return float(value)
            except:
                return None
        return None
```

#### Streaming Protocol

```python
class SAOStreamingDevice(SAOWithUART):
    """SAO device with continuous data streaming."""
    
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.stream_active = False
        self.stream_callback = None
    
    async def start_streaming(self, callback):
        """
        Start receiving streaming data.
        
        Args:
            callback: Async function called with each received line
        """
        self.stream_active = True
        self.stream_callback = callback
        
        # Send start command
        self.uart_write('START\n')
        
        # Receive loop
        while self.stream_active:
            line = await self.uart_read_line(timeout_ms=100)
            if line and self.stream_callback:
                await self.stream_callback(line)
    
    def stop_streaming(self):
        """Stop streaming."""
        self.stream_active = False
        self.uart_write('STOP\n')
```

### UART Performance Considerations

**Baud Rate Selection**:
- **9600 bps**: Most reliable, good for short messages
- **19200 bps**: Good balance of speed and reliability
- **38400 bps**: Fast, requires accurate timing
- **57600+ bps**: Challenging with software UART, may have errors

**Timing Accuracy**:
- Software UART timing depends on CPU availability
- Disable interrupts during transmission for accuracy
- Use hardware timers if available for better precision
- Lower baud rates are more tolerant of timing variations

**Best Practices**:
- Keep messages short for software UART
- Use checksums for data integrity
- Implement retransmission for critical data
- Consider using hardware UART if available on unused pins

## Testing and Debugging

### Testing Hardware Connection

```python
def test_hardware():
    """Test basic hardware connectivity."""
    from machine import Pin, I2C
    
    print("=== SAO Hardware Test ===\n")
    
    # Test I2C pins
    print("1. Testing I2C pins...")
    try:
        sda = Pin(8, Pin.OUT)
        scl = Pin(10, Pin.OUT)
        
        # Toggle pins
        for _ in range(3):
            sda.value(1)
            scl.value(1)
            time.sleep_ms(100)
            sda.value(0)
            scl.value(0)
            time.sleep_ms(100)
        
        print("   ✓ I2C pins responding")
    except Exception as e:
        print(f"   ✗ I2C pin error: {e}")
    
    # Test I2C bus
    print("\n2. Testing I2C bus...")
    try:
        i2c = I2C(0, scl=Pin(10), sda=Pin(8), freq=100000)
        devices = i2c.scan()
        print(f"   Found {len(devices)} I2C device(s)")
        for addr in devices:
            print(f"   - Address: 0x{addr:02x}")
        
        if 0x50 in devices:
            print("   ✓ SAO EEPROM detected at 0x50")
        else:
            print("   ✗ No SAO EEPROM at 0x50")
    except Exception as e:
        print(f"   ✗ I2C bus error: {e}")
    
    # Test GPIO pins
    print("\n3. Testing GPIO pins...")
    try:
        gpio1 = Pin(39, Pin.OUT)
        gpio2 = Pin(40, Pin.OUT)
        
        # Blink test
        for _ in range(3):
            gpio1.value(1)
            gpio2.value(0)
            time.sleep_ms(100)
            gpio1.value(0)
            gpio2.value(1)
            time.sleep_ms(100)
        
        gpio1.value(0)
        gpio2.value(0)
        print("   ✓ GPIO pins responding")
    except Exception as e:
        print(f"   ✗ GPIO error: {e}")
    
    print("\n=== Test Complete ===")
```

### Debugging EEPROM Communication

```python
def debug_eeprom():
    """Debug EEPROM reading with detailed output."""
    from drivers.sao_base import SAOBase
    
    print("=== EEPROM Debug ===\n")
    
    sao = SAOBase(sda_pin=8, scl_pin=10)
    
    # Scan I2C bus
    print("I2C Scan:")
    devices = sao.i2c.scan()
    for addr in devices:
        print(f"  0x{addr:02x} ({addr})")
    
    if 0x50 not in devices:
        print("\nERROR: No device at 0x50")
        return
    
    print("\nReading EEPROM:")
    
    # Read first 256 bytes
    try:
        for addr in range(0, 256, 16):
            # Read 16 bytes
            data = sao.read_eeprom(addr, 16)
            
            # Format as hex
            hex_str = ' '.join(f'{b:02x}' for b in data)
            
            # Format as ASCII
            ascii_str = ''.join(chr(b) if 32 <= b < 127 else '.' for b in data)
            
            print(f"{addr:04x}: {hex_str}  {ascii_str}")
            
            # Check for end of data (all 0xFF)
            if all(b == 0xFF for b in data):
                print("(End of programmed data)")
                break
    
    except Exception as e:
        print(f"Error reading EEPROM: {e}")
```

### Testing UART Communication

```python
async def test_uart():
    """Test software UART communication."""
    from drivers.sao_base import SAOBase
    
    # Create SAO with UART
    sao = SAOWithUART(
        sda_pin=8,
        scl_pin=10,
        gpio1_pin=39,  # TX
        gpio2_pin=40,  # RX
        baudrate=9600
    )
    
    print("=== UART Test ===\n")
    
    # Configure GPIO pins for UART
    sao.gpio1.init(mode=Pin.OUT, value=1)  # TX idle high
    sao.gpio2.init(mode=Pin.IN, pull=Pin.PULL_UP)  # RX
    
    # Test transmission
    print("1. Sending test message...")
    sao.uart_write("Hello SAO!\n")
    print("   Sent: 'Hello SAO!'")
    
    # Test reception (if device echoes or sends data)
    print("\n2. Waiting for response...")
    response = await sao.uart_read_line(timeout_ms=2000)
    if response:
        print(f"   Received: '{response}'")
    else:
        print("   No response (timeout)")
    
    print("\n=== Test Complete ===")
```

### Common Issues and Solutions

#### Issue: SAO Not Detected

**Symptoms**: `scan()` doesn't return 0x50

**Solutions**:
1. Check physical connections (VCC, GND, SDA, SCL)
2. Verify correct pin numbers in code
3. Try lower I2C frequency (50kHz): `I2C(0, ..., freq=50000)`
4. Check SAO has EEPROM at 0x50 (consult SAO documentation)
5. Use multimeter to verify 3.3V on VCC pin
6. Check for short circuits

#### Issue: EEPROM Read Errors

**Symptoms**: `read_eeprom()` raises exceptions

**Solutions**:
1. Add longer delays between operations: `time.sleep_ms(10)`
2. Reduce I2C speed: `freq=50000`
3. Check for I2C bus contention (other devices)
4. Verify EEPROM is not write-protected
5. Try reading smaller chunks (8 bytes at a time)

#### Issue: GPIO Not Responding

**Symptoms**: GPIO operations don't affect SAO

**Solutions**:
1. Verify pin configuration (IN vs OUT, pull-ups)
2. Check if GPIO pins are connected
3. Measure voltage on GPIO pins with multimeter
4. Try different GPIO pin numbers
5. Check SAO schematic for GPIO requirements (voltage, current)

#### Issue: UART Communication Failures

**Symptoms**: No data received, garbled data

**Solutions**:
1. **Lower baud rate**: Try 9600, then 4800 bps
2. **Check timing**: Software UART needs consistent timing
3. **Verify pin configuration**: TX=OUT, RX=IN with pull-up
4. **Check voltage levels**: Ensure 3.3V compatibility
5. **Test loopback**: Connect TX to RX, send and receive same data
6. **Add delays**: Increase `bit_time_us` slightly for timing margin
7. **Disable interrupts**: Minimize interrupt activity during UART

## Complete Examples

### Example 1: Simple LED SAO

```python
"""
Simple LED SAO Example

SAO with RGB LED controlled via I2C (e.g., using PCA9685 or similar).
"""

from drivers.sao_base import SAOBase
from machine import Pin
import time


class LEDSAODriver(SAOBase):
    """Driver for LED SAO with I2C LED controller."""
    
    # I2C commands for LED controller (example for PCA9685-style)
    MODE1_REG = 0x00
    LED0_REG = 0x06
    
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.i2c_addr = 0x40  # LED controller address (adjust for your SAO)
    
    def detect_controller(self):
        """Check if LED controller is present."""
        devices = self.i2c.scan()
        return self.i2c_addr in devices
    
    def init_controller(self):
        """Initialize LED controller."""
        try:
            # Wake up controller
            self.i2c.writeto_mem(self.i2c_addr, self.MODE1_REG, bytes([0x00]))
            time.sleep_ms(1)
            return True
        except Exception as e:
            print(f"Controller init failed: {e}")
            return False
    
    def set_led_pwm(self, channel, value):
        """
        Set LED PWM value.
        
        Args:
            channel: LED channel (0-15)
            value: PWM value (0-4095)
        """
        reg = self.LED0_REG + (channel * 4)
        # Set LED on at 0, off at value
        data = bytes([0, 0, value & 0xFF, (value >> 8) & 0xFF])
        self.i2c.writeto_mem(self.i2c_addr, reg, data)
    
    def set_rgb(self, r, g, b):
        """
        Set RGB LED color.
        
        Args:
            r, g, b: Color values (0-255)
        """
        # Convert 0-255 to 0-4095
        r_pwm = int((r / 255) * 4095)
        g_pwm = int((g / 255) * 4095)
        b_pwm = int((b / 255) * 4095)
        
        self.set_led_pwm(0, r_pwm)  # Red on channel 0
        self.set_led_pwm(1, g_pwm)  # Green on channel 1
        self.set_led_pwm(2, b_pwm)  # Blue on channel 2
    
    async def color_cycle(self, duration_ms=5000):
        """Cycle through colors."""
        colors = [
            (255, 0, 0),    # Red
            (255, 128, 0),  # Orange
            (255, 255, 0),  # Yellow
            (0, 255, 0),    # Green
            (0, 255, 255),  # Cyan
            (0, 0, 255),    # Blue
            (255, 0, 255),  # Magenta
        ]
        
        delay = duration_ms // len(colors)
        for r, g, b in colors:
            self.set_rgb(r, g, b)
            await asyncio.sleep_ms(delay)


# Usage
async def demo_led_sao():
    # Initialize SAO
    sao = LEDSAODriver(sda_pin=8, scl_pin=10)
    
    # Detect SAO
    if not sao.detect():
        print("SAO not found")
        return
    
    info = sao.parse_eeprom_info()
    print(f"Found SAO: {info['name']}")
    
    # Initialize LED controller
    if not sao.detect_controller():
        print("LED controller not found")
        return
    
    sao.init_controller()
    
    # Color cycle
    print("Starting color cycle...")
    await sao.color_cycle(duration_ms=7000)
    
    # Turn off
    sao.set_rgb(0, 0, 0)
    print("Demo complete")
```

### Example 2: Sensor SAO with UART

```python
"""
Sensor SAO Example

SAO with temperature/humidity sensor communicating via UART.
"""

from drivers.sao_base import SAOWithUART
import json


class SensorSAODriver(SAOWithUART):
    """Driver for sensor SAO using UART protocol."""
    
    def __init__(self, **kwargs):
        super().__init__(baudrate=9600, **kwargs)
        
        # Sensor state
        self.temperature = None
        self.humidity = None
        self.last_update = 0
    
    async def initialize(self):
        """Initialize sensor."""
        # Send init command
        response = await self.uart_command_response('INIT')
        if response and response.startswith('OK'):
            print("Sensor initialized")
            return True
        else:
            print("Sensor init failed")
            return False
    
    async def read_sensor_data(self):
        """
        Read temperature and humidity.
        
        Returns:
            dict: {'temperature': float, 'humidity': float} or None
        """
        # Send read command
        response = await self.uart_command_response('READ', timeout_ms=500)
        
        if not response:
            return None
        
        try:
            # Parse response: "OK 25.3,65.2" (temp,humidity)
            if response.startswith('OK '):
                values = response[3:].split(',')
                self.temperature = float(values[0])
                self.humidity = float(values[1])
                self.last_update = time.time()
                
                return {
                    'temperature': self.temperature,
                    'humidity': self.humidity,
                    'timestamp': self.last_update
                }
        except Exception as e:
            print(f"Parse error: {e}")
        
        return None
    
    async def monitor_sensor(self, interval_sec=5, callback=None):
        """
        Continuously monitor sensor.
        
        Args:
            interval_sec: Reading interval in seconds
            callback: Optional async function called with each reading
        """
        while True:
            data = await self.read_sensor_data()
            
            if data:
                print(f"Temp: {data['temperature']}°C, "
                      f"Humidity: {data['humidity']}%")
                
                if callback:
                    await callback(data)
            else:
                print("Read failed")
            
            await asyncio.sleep(interval_sec)


# Usage
async def demo_sensor_sao():
    # Initialize SAO
    sao = SensorSAODriver(
        sda_pin=8,
        scl_pin=10,
        gpio1_pin=39,  # TX
        gpio2_pin=40,  # RX
    )
    
    # Detect SAO
    if not sao.detect():
        print("SAO not found")
        return
    
    info = sao.parse_eeprom_info()
    print(f"Found SAO: {info['name']}")
    
    # Initialize sensor
    if not await sao.initialize():
        return
    
    # Read once
    data = await sao.read_sensor_data()
    if data:
        print(f"Temperature: {data['temperature']}°C")
        print(f"Humidity: {data['humidity']}%")
    
    # Monitor continuously
    print("\nStarting continuous monitoring...")
    await sao.monitor_sensor(interval_sec=2)
```

### Example 3: Interactive Button SAO

```python
"""
Interactive Button SAO Example

SAO with multiple buttons and LEDs for badge interaction.
"""

from drivers.sao_base import SAOBase
from machine import Pin
import asyncio


class ButtonSAODriver(SAOBase):
    """Driver for button SAO with LEDs."""
    
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        
        # Configure GPIO pins
        # GPIO1 = LED output, GPIO2 = Button input
        if self.gpio1:
            self.gpio1.init(mode=Pin.OUT, value=0)
        if self.gpio2:
            self.gpio2.init(mode=Pin.IN, pull=Pin.PULL_UP)
        
        self.button_callback = None
        self.led_state = False
    
    def led_set(self, state):
        """Set LED state."""
        if self.gpio1:
            self.gpio1.value(1 if state else 0)
            self.led_state = state
    
    def led_toggle(self):
        """Toggle LED."""
        self.led_set(not self.led_state)
    
    def is_button_pressed(self):
        """Check if button is pressed."""
        if self.gpio2:
            return self.gpio2.value() == 0  # Active low
        return False
    
    async def wait_for_press(self, timeout_ms=None):
        """
        Wait for button press.
        
        Args:
            timeout_ms: Timeout in milliseconds (None = no timeout)
            
        Returns:
            bool: True if pressed, False if timeout
        """
        start = time.ticks_ms()
        last_state = self.is_button_pressed()
        
        while True:
            current_state = self.is_button_pressed()
            
            # Detect press (low) with debounce
            if current_state and not last_state:
                await asyncio.sleep_ms(50)  # Debounce
                if self.is_button_pressed():
                    return True
            
            last_state = current_state
            
            # Check timeout
            if timeout_ms is not None:
                if time.ticks_diff(time.ticks_ms(), start) > timeout_ms:
                    return False
            
            await asyncio.sleep_ms(10)
    
    async def button_led_game(self, rounds=5):
        """
        Simple reaction game: press button when LED lights up.
        
        Args:
            rounds: Number of rounds to play
            
        Returns:
            list: Reaction times in milliseconds
        """
        import random
        
        reaction_times = []
        
        print("Button LED Game!")
        print("Press button when LED turns on")
        await asyncio.sleep(2)
        
        for round_num in range(rounds):
            print(f"\nRound {round_num + 1}/{rounds}")
            
            # Random delay
            delay = random.randint(1000, 3000)
            await asyncio.sleep_ms(delay)
            
            # Turn on LED and measure reaction time
            self.led_set(True)
            start = time.ticks_ms()
            
            pressed = await self.wait_for_press(timeout_ms=2000)
            
            if pressed:
                reaction_ms = time.ticks_diff(time.ticks_ms(), start)
                reaction_times.append(reaction_ms)
                print(f"Reaction time: {reaction_ms}ms")
            else:
                print("Too slow!")
            
            self.led_set(False)
            await asyncio.sleep(1)
        
        # Results
        if reaction_times:
            avg = sum(reaction_times) / len(reaction_times)
            best = min(reaction_times)
            print(f"\nResults:")
            print(f"  Average: {avg:.0f}ms")
            print(f"  Best: {best}ms")
        
        return reaction_times


# Usage
async def demo_button_sao():
    # Initialize SAO
    sao = ButtonSAODriver(
        sda_pin=8,
        scl_pin=10,
        gpio1_pin=39,  # LED
        gpio2_pin=40,  # Button
    )
    
    # Detect SAO
    if not sao.detect():
        print("SAO not found")
        return
    
    info = sao.parse_eeprom_info()
    print(f"Found SAO: {info['name']}")
    
    # Play game
    await sao.button_led_game(rounds=3)
```

## References

### SAO Standard

- **SAO Standard v1.69bis**: https://badge.team/docs/standards/sao/ (Original specification)
- **Hackaday SAO Resources**: https://hackaday.io/search?term=sao (Community projects)
- **SAO Specifications**: https://hackaday.com/tag/sao/ (Articles and designs)

### ESP32-S3 Documentation

- **ESP32-S3 Technical Reference**: https://www.espressif.com/sites/default/files/documentation/esp32-s3_technical_reference_manual_en.pdf
- **ESP32-S3 Datasheet**: See `docs/hardware/esp32-s3-wroom-2_datasheet_en.pdf`
- **MicroPython ESP32 Docs**: https://docs.micropython.org/en/latest/esp32/quickref.html

### MicroPython Resources

- **MicroPython I2C**: https://docs.micropython.org/en/latest/library/machine.I2C.html
- **MicroPython Pin**: https://docs.micropython.org/en/latest/library/machine.Pin.html
- **MicroPython UART**: https://docs.micropython.org/en/latest/library/machine.UART.html

### Badge Firmware Documentation

- **Game Development Guide**: [docs/game_development.md](game_development.md)
- **Hardware Documentation**: [HARDWARE.md](../HARDWARE.md)
- **Development Guide**: [DEVELOPMENT.md](../DEVELOPMENT.md)

### I2C and UART

- **I2C Specification**: https://www.nxp.com/docs/en/user-guide/UM10204.pdf
- **UART Communication**: https://www.analog.com/en/analog-dialogue/articles/uart-a-hardware-communication-protocol.html
- **Software UART Design**: https://www.nxp.com/docs/en/application-note/AN4030.pdf

---

## Contributing

If you develop an SAO driver for the Disobey Badge, consider contributing it back to the community:

1. Fork the repository
2. Add your driver to `/frozen_firmware/modules/drivers/sao_YOUR_DEVICE.py`
3. Add example usage to `/firmware/examples/sao_YOUR_DEVICE_demo.py`
4. Update this documentation with your SAO details
5. Submit a pull request

### Driver Checklist

- [ ] Inherits from `SAOBase` or `SAOWithUART`
- [ ] Includes docstrings for all public methods
- [ ] Handles errors gracefully
- [ ] Includes example usage
- [ ] Works with live firmware directory mounting
- [ ] Tested on actual hardware
- [ ] Memory efficient (suitable for embedded use)
- [ ] Follows badge coding conventions

---

**Happy SAO development!** If you have questions or need help, reach out on the [Disobey Discord](https://discord.gg/S7eMF3TQCj) in the #badge channel.
