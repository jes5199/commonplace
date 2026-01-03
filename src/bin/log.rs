//! commonplace-log: Show commit history for a synced file (like git log)
//!
//! Usage:
//!   commonplace-log path/to/file.txt               # Full log output
//!   commonplace-log --oneline path/to/file.txt     # Compact one-line format
//!   commonplace-log --stat path/to/file.txt        # Show change statistics
//!   commonplace-log -n 5 path/to/file.txt          # Limit to 5 commits
//!   commonplace-log --since 2024-01-01 path.txt    # Commits after date

use clap::Parser;
use commonplace_doc::cli::LogArgs;
use commonplace_doc::workspace::{
    format_timestamp, format_timestamp_short, parse_date, resolve_path_to_uuid,
};
use reqwest::Client;
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
struct CommitChange {
    #[allow(dead_code)]
    doc_id: String,
    commit_id: String,
    timestamp: u64,
    #[allow(dead_code)]
    url: String,
}

#[derive(Deserialize)]
struct ChangesResponse {
    changes: Vec<CommitChange>,
}

#[derive(Deserialize)]
struct HeadResponse {
    #[allow(dead_code)]
    cid: Option<String>,
    content: Option<String>,
}

#[derive(Serialize)]
struct CommitInfo {
    cid: String,
    timestamp: u64,
    datetime: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    stats: Option<ChangeStats>,
}

#[derive(Serialize, Clone)]
struct ChangeStats {
    lines_added: usize,
    lines_removed: usize,
    chars_added: usize,
    chars_removed: usize,
}

#[derive(Serialize)]
struct LogOutput {
    uuid: String,
    path: String,
    commits: Vec<CommitInfo>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = LogArgs::parse();

    // Resolve file path to UUID
    let (uuid, _workspace_root, rel_path) = resolve_path_to_uuid(&args.path)?;

    let client = Client::new();

    // Fetch commit history
    let url = format!("{}/documents/{}/changes", args.server, uuid);
    let resp = client.get(&url).send().await?;

    if !resp.status().is_success() {
        eprintln!("Failed to fetch changes: HTTP {}", resp.status());
        std::process::exit(1);
    }

    let mut changes: ChangesResponse = resp.json().await?;

    // Reverse to show newest first (git log order) - API returns oldest first
    changes.changes.reverse();

    // Apply date filters
    if let Some(ref since) = args.since {
        if let Some(since_ts) = parse_date(since) {
            changes.changes.retain(|c| c.timestamp >= since_ts);
        } else {
            eprintln!("Warning: could not parse --since date: {}", since);
        }
    }

    if let Some(ref until) = args.until {
        if let Some(until_ts) = parse_date(until) {
            changes.changes.retain(|c| c.timestamp <= until_ts);
        } else {
            eprintln!("Warning: could not parse --until date: {}", until);
        }
    }

    // Apply max count limit
    if let Some(max) = args.max_count {
        changes.changes.truncate(max);
    }

    // Compute stats if requested
    let stats_map: Option<Vec<Option<ChangeStats>>> = if args.stat {
        Some(compute_stats(&client, &args.server, &uuid, &changes.changes).await?)
    } else {
        None
    };

    if args.json {
        let commits: Vec<CommitInfo> = changes
            .changes
            .iter()
            .enumerate()
            .map(|(i, c)| CommitInfo {
                cid: c.commit_id.clone(),
                timestamp: c.timestamp,
                datetime: format_timestamp(c.timestamp),
                stats: stats_map.as_ref().and_then(|m| m.get(i).cloned().flatten()),
            })
            .collect();

        let output = LogOutput {
            uuid: uuid.clone(),
            path: rel_path.clone(),
            commits,
        };
        println!("{}", serde_json::to_string_pretty(&output)?);
    } else if args.oneline {
        // Compact one-line format: cid_short date message
        for (i, change) in changes.changes.iter().enumerate() {
            let cid_short = &change.commit_id[..12.min(change.commit_id.len())];
            let date = format_timestamp_short(change.timestamp);

            if args.stat {
                if let Some(ref stats_vec) = stats_map {
                    if let Some(Some(stats)) = stats_vec.get(i) {
                        println!(
                            "{} {} (+{} -{} chars)",
                            cid_short, date, stats.chars_added, stats.chars_removed
                        );
                        continue;
                    }
                }
            }
            println!("{} {}", cid_short, date);
        }
    } else if args.graph {
        // ASCII graph view - for now just show a simple linear graph
        // Full DAG graph support would require fetching parent info
        print_graph_view(&changes.changes, stats_map.as_ref());
    } else {
        // Full output (like git log)
        println!("File: {}", rel_path);
        println!("UUID: {}", uuid);
        println!();

        for (i, change) in changes.changes.iter().enumerate() {
            println!("commit {}", change.commit_id);
            println!("Date:   {}", format_timestamp(change.timestamp));

            if args.stat {
                if let Some(ref stats_vec) = stats_map {
                    if let Some(Some(stats)) = stats_vec.get(i) {
                        println!();
                        println!(
                            " {} chars (+{}/-{}), {} lines (+{}/-{})",
                            stats.chars_added + stats.chars_removed,
                            stats.chars_added,
                            stats.chars_removed,
                            stats.lines_added + stats.lines_removed,
                            stats.lines_added,
                            stats.lines_removed
                        );
                    }
                }
            }
            println!();
        }

        println!("{} commits", changes.changes.len());
    }

    Ok(())
}

fn print_graph_view(changes: &[CommitChange], stats_map: Option<&Vec<Option<ChangeStats>>>) {
    // Simple linear graph - for now we don't have parent info
    // Full graph would need to fetch commit parents from server
    for (i, change) in changes.iter().enumerate() {
        let cid_short = &change.commit_id[..8.min(change.commit_id.len())];
        let date = format_timestamp_short(change.timestamp);
        let is_last = i == changes.len() - 1;

        let connector = if is_last { "  " } else { "| " };

        print!("* {} {}", cid_short, date);

        if let Some(stats_vec) = stats_map {
            if let Some(Some(stats)) = stats_vec.get(i) {
                print!(" (+{} -{} chars)", stats.chars_added, stats.chars_removed);
            }
        }
        println!();

        if !is_last {
            println!("{}", connector);
        }
    }
}

async fn compute_stats(
    client: &Client,
    server: &str,
    uuid: &str,
    changes: &[CommitChange],
) -> Result<Vec<Option<ChangeStats>>, Box<dyn std::error::Error>> {
    let mut result = Vec::with_capacity(changes.len());

    // We need content at each commit and the previous one to compute diffs
    // For efficiency, we'll fetch content sequentially and diff with previous
    let mut prev_content: Option<String> = None;

    // Sort by timestamp to process chronologically
    let mut sorted_indices: Vec<usize> = (0..changes.len()).collect();
    sorted_indices.sort_by_key(|&i| changes[i].timestamp);

    // Map from original index to stats
    let mut stats_by_index: std::collections::HashMap<usize, ChangeStats> =
        std::collections::HashMap::new();

    for &orig_idx in &sorted_indices {
        let change = &changes[orig_idx];
        let url = format!(
            "{}/docs/{}/head?at_commit={}",
            server, uuid, change.commit_id
        );

        match client.get(&url).send().await {
            Ok(resp) if resp.status().is_success() => {
                if let Ok(head) = resp.json::<HeadResponse>().await {
                    if let Some(content) = head.content {
                        let stats = if let Some(ref prev) = prev_content {
                            compute_diff_stats(prev, &content)
                        } else {
                            // First commit - all additions
                            ChangeStats {
                                lines_added: content.lines().count(),
                                lines_removed: 0,
                                chars_added: content.len(),
                                chars_removed: 0,
                            }
                        };
                        stats_by_index.insert(orig_idx, stats);
                        prev_content = Some(content);
                    }
                }
            }
            _ => {
                // Skip commits we can't fetch
            }
        }
    }

    // Build result in original order
    for i in 0..changes.len() {
        result.push(stats_by_index.remove(&i));
    }

    Ok(result)
}

fn compute_diff_stats(old: &str, new: &str) -> ChangeStats {
    // Simple line-based diff stats
    let old_lines: std::collections::HashSet<&str> = old.lines().collect();
    let new_lines: std::collections::HashSet<&str> = new.lines().collect();

    let added: usize = new_lines.difference(&old_lines).count();
    let removed: usize = old_lines.difference(&new_lines).count();

    // Character diff (simple approximation)
    let chars_added = if new.len() > old.len() {
        new.len() - old.len()
    } else {
        0
    };
    let chars_removed = if old.len() > new.len() {
        old.len() - new.len()
    } else {
        0
    };

    ChangeStats {
        lines_added: added,
        lines_removed: removed,
        chars_added,
        chars_removed,
    }
}
