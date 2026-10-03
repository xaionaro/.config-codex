package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
)

const (
	// traceCaptureByteLimit bounds complete retained Trace2 capture independently of history size.
	//
	// Example: a larger native log is drained but its observation is Advisory.
	traceCaptureByteLimit = 8 * 1024 * 1024
	// traceCaptureEventLimit bounds decoded events within a complete capture.
	//
	// Example: 8193 short records cannot establish a complete supported observation.
	traceCaptureEventLimit = 8192
)

// traceCapture owns an inherited write channel and its bounded, concurrently drained result.
//
// Example: Git receives Writer as FD4 while the collector retains at most its byte limit.
type traceCapture struct {
	Writer *os.File
	done   chan traceCaptureResult
}

// traceCaptureResult reports complete draining separately from retained bytes.
//
// Example: overflow is an error even though the native producer reached EOF successfully.
type traceCaptureResult struct {
	Data []byte
	Err  error
}

// newTraceCapture begins draining an owned pipe until EOF or the shared observation cancellation.
//
// Example: cancellation closes a stalled reader and joins its callback before reporting completion.
func newTraceCapture(
	ctx context.Context,
	limit int,
) (*traceCapture, error) {
	reader, writer, err := os.Pipe()
	if err != nil {
		return nil, fmt.Errorf("create trace capture pipe: %w", err)
	}
	capture := &traceCapture{Writer: writer, done: make(chan traceCaptureResult, 1)}
	// The selected transport requires concurrent drain without adding a runtime dependency.
	go func() {
		output := boundedOutput{limit: limit}
		cancelled := make(chan error, 1)
		// Closing the owned reader unblocks an opaque inherited channel at the same deadline.
		stop := context.AfterFunc(ctx, func() { cancelled <- reader.Close() })
		_, copyErr := io.Copy(&output, reader)
		var closeErr error
		if stop() {
			closeErr = reader.Close()
		} else {
			closeErr = <-cancelled
		}
		if ctx.Err() != nil {
			copyErr = errors.Join(copyErr, ctx.Err())
		}
		if output.overflow {
			copyErr = errors.Join(copyErr, fmt.Errorf("native trace capture exceeded supported size"))
		}
		capture.done <- traceCaptureResult{Data: output.buffer.Bytes(), Err: errors.Join(copyErr, closeErr)}
	}()
	return capture, nil
}

// finish closes the parent's writer and joins complete collection on every path.
//
// Example: a failed native Start still reaches EOF rather than leaking a collector.
func (capture *traceCapture) finish() ([]byte, error) {
	closeErr := capture.Writer.Close()
	result := <-capture.done
	return result.Data, errors.Join(closeErr, result.Err)
}

// decodeTraceCapture accepts only complete, bounded, lossless records under the observation context.
//
// Example: a truncated final JSON record or an event beyond the cap yields no usable evidence.
func decodeTraceCapture(
	ctx context.Context,
	data []byte,
) ([]traceEvent, error) {
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("decode native trace: %w", err)
	}
	if len(data) > traceCaptureByteLimit {
		return nil, fmt.Errorf("native trace capture exceeded supported size")
	}
	if len(data) > 0 && data[len(data)-1] != '\n' {
		return nil, fmt.Errorf("incomplete native trace record")
	}
	events := []traceEvent{}
	scanner := bufio.NewScanner(bytes.NewReader(data))
	scanner.Buffer(make([]byte, 4096), traceEventByteLimit)
	for scanner.Scan() {
		if err := ctx.Err(); err != nil {
			return nil, fmt.Errorf("decode native trace: %w", err)
		}
		if len(events) == traceCaptureEventLimit {
			return nil, fmt.Errorf("native trace event count exceeded supported size")
		}
		if !exactJSONUnicode(scanner.Bytes()) {
			return nil, fmt.Errorf("lossy native trace Unicode encoding")
		}
		var event traceEvent
		if err := json.Unmarshal(scanner.Bytes(), &event); err != nil {
			return nil, fmt.Errorf("decode trace: %w", err)
		}
		events = append(events, event)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read native trace record: %w", err)
	}
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("decode native trace: %w", err)
	}
	return events, nil
}
