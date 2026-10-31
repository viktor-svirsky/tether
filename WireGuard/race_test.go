//go:build race

package main

// raceEnabled is true under -race, which slows gVisor down a hundredfold. The busiest tests do
// less then, and some don't run at all (see fullSizeOnly), so CI stays quick. The ones left still
// run their goroutines side by side for the detector.
const raceEnabled = true
