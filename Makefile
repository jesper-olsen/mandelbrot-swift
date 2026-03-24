# Variables
SWIFTC = swiftc
SWIFT_FLAGS = -Ounchecked
TARGET = mandelbrot

all: $(TARGET)

$(TARGET): mandelbrot.swift
	$(SWIFTC) $(SWIFT_FLAGS) mandelbrot.swift -o $(TARGET)

small: mandelbrot
	time ./mandelbrot png=1 width=1000 height=750 > image.dat
	gnuplot topng.gp

large: mandelbrot
	time ./mandelbrot png=1 width=5000 height=5000 > image.dat
	gnuplot topng.gp

clean:
	rm -f $(TARGET)
