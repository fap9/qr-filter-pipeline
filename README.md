# QR-Code-Filter-Pipeline

Bildverarbeitungspipeline in VHDL auf der programmierbaren Logik eines
Zynq-7000 (ZedBoard, `xc7z020clg484-1`). Das Prozessorsystem erzeugt einen
synthetischen QR-Code mit Salt-and-Pepper-Rauschen im DDR-Speicher und streamt
ihn über einen AXI VDMA durch die Kette aus Grauwertkonvertierung, Medianfilter
3x3 und Gauss-Filter 3x3.


## Inhalt

| Pfad | Inhalt |
|---|---|
| `hdl/` | Filtermodule, Top-Entity, Reset-Monitor |
| `sim/` | Selbstprüfende Testbenches |
| `src/`, `include/` | Bare-Metal-Software: Testbilderzeugung, Softwarereferenz, VDMA-Ansteuerung, Messschleife |
| `build_pipeline.tcl` | Baut Vivado-Projekt und Blockdesign |
| `zedboard_leds.xdc` | Pinbelegung LD0 bis LD4 |
| `measurment_final.csv` | Messwerte des Abschlusslaufs, 90 Frames |

## Werkzeuge

Vivado und Vitis 2025.2, Ubuntu 24.04.

## Lizenz

MIT, siehe `LICENSE`. Die Dateien `include/qrcodegen.hpp` und
`src/qrcodegen.cpp` stammen aus dem Projekt QR Code generator von Project
Nayuki und stehen unter eigener MIT-Lizenz, der Vermerk steht im Dateikopf.
