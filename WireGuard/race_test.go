//go:build race

package main

// raceEnabled is true under -race, which slows gVisor down a hundredfold. The busiest tests do
// less then, so CI stays quick, and still run their goroutines side by side for the detector.
const raceEnabled = true
