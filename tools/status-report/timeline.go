package main

import (
	"fmt"
	"strings"
)

// writeTimeline renders each Job's supplied history in three columns.
//
// Example: A Job with Fast and normal events gets one table of its intervals.
func writeTimeline(b *strings.Builder, entries []map[string]any) {
	if len(entries) == 0 {
		fmt.Fprintln(b, "Timeline history unavailable or no evidenced progress; consult source evidence.")
		return
	}
	groups := make(map[string][]map[string]any)
	var jobs []string
	for _, entry := range entries {
		job := timelineCell(entry["job"])
		if _, ok := groups[job]; !ok {
			jobs = append(jobs, job)
		}
		groups[job] = append(groups[job], entry)
	}
	for _, job := range jobs {
		rows := groups[job]
		chain := timelineCell(rows[0]["parent_chain"])
		fmt.Fprintf(b, "Job %s (parent chain: %s)\n\n", job, chain)
		fmt.Fprintln(b, "| UTC interval | Fast | Normal |")
		fmt.Fprintln(b, "| --- | --- | --- |")
		for _, row := range rows {
			fmt.Fprintf(b, "| %s | %s | %s |\n", timelineCell(row["interval"]), timelineCell(row["fast"]), timelineCell(row["normal"]))
		}
		fmt.Fprintln(b)
		for _, row := range rows {
			for _, field := range []string{"evidence", "uncertainty"} {
				if row[field] != nil && strings.TrimSpace(fmt.Sprint(row[field])) != "" {
					fmt.Fprintf(b, "- %s %s: %s\n", timelineCell(row["interval"]), field, timelineCell(row[field]))
				}
			}
		}
		fmt.Fprintln(b)
	}
}

// timelineCell renders a supplied value safely within a Markdown table cell.
//
// Example: A missing path history renders as unknown.
func timelineCell(value any) string {
	if value == nil || strings.TrimSpace(fmt.Sprint(value)) == "" {
		return "unknown"
	}
	cell := strings.ReplaceAll(fmt.Sprint(value), "|", "\\|")
	return strings.ReplaceAll(cell, "\n", "<br>")
}
