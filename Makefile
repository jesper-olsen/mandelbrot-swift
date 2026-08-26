# Variables
SWIFTC = swiftc
SWIFT_FLAGS = -Ounchecked

TARGET = mandelbrot
TARGET_THREADED = mandelbrot_threaded
TARGET_SIMD_THREADED = mandelbrot_simd_threaded

all: $(TARGET) $(TARGET_THREADED) $(TARGET_SIMD_THREADED)

$(TARGET): mandelbrot.swift
	$(SWIFTC) $(SWIFT_FLAGS) mandelbrot.swift -o $(TARGET)

$(TARGET_THREADED): mandelbrot_threaded.swift
	$(SWIFTC) $(SWIFT_FLAGS) mandelbrot_threaded.swift -o $(TARGET_THREADED)

$(TARGET_SIMD_THREADED): mandelbrot_simd_threaded.swift
	$(SWIFTC) $(SWIFT_FLAGS) mandelbrot_simd_threaded.swift -o $(TARGET_SIMD_THREADED)

small: $(TARGET)
	time ./$(TARGET) png=1 width=1000 height=750 > image.dat
	gnuplot topng.gp

large: $(TARGET)
	time ./$(TARGET) png=1 width=5000 height=5000 > image.dat
	gnuplot topng.gp

large-threaded: $(TARGET_THREADED)
	time ./$(TARGET_THREADED) png=1 width=5000 height=5000 > image.dat
	gnuplot topng.gp

large-simd-threaded: $(TARGET_SIMD_THREADED)
	time ./$(TARGET_SIMD_THREADED) png=1 width=5000 height=5000 > image.dat
	gnuplot topng.gp

clean:
	rm -f $(TARGET) $(TARGET_THREADED) $(TARGET_SIMD_THREADED)
