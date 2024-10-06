import re
from datetime import datetime
from sys import argv
import matplotlib.pyplot as plt
import matplotlib.dates as mdates

def parse_log_line(line):
    # Match the entire line pattern including height
    match = re.search(r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z).*height=(\d+).*cache=(\d+\.\d+)MiB', line)

    if match:
        timestamp_str, height_str, cache_size_str = match.groups()
        height = int(height_str)

        # Only process the line if height is >= 840000
        if height >= 840000:
            timestamp = datetime.strptime(timestamp_str, '%Y-%m-%dT%H:%M:%SZ')
            cache_size = float(cache_size_str)
            return timestamp, cache_size
    
    return None

def analyze_log_file(log_content):
    data = []
    for line in log_content.split('\n'):
        parsed = parse_log_line(line)
        if parsed:
            data.append(parsed)
    return data

def plot_cache_size(data, output_file):
    timestamps, cache_sizes = zip(*data)
    
    fig, ax = plt.subplots(figsize=(12, 6))
    ax.plot(timestamps, cache_sizes, marker='o')
    
    ax.set_xlabel('Time')
    ax.set_ylabel('Cache Size (MiB)')
    ax.set_title('Cache Size Changes Over Time')
    
    ax.xaxis.set_major_formatter(mdates.DateFormatter('%Y-%m-%d %H:%M:%S'))
    plt.xticks(rotation=45)
    
    plt.tight_layout()
    plt.savefig(output_file, dpi=300, bbox_inches='tight')
    print(f"Graph saved as {output_file}")

debug_log_file = argv[1]
output_file = argv[2]

with open(debug_log_file, 'r') as file:
    log_content = file.read()

data = analyze_log_file(log_content)
plot_cache_size(data, output_file)
