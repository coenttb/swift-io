#!/bin/bash

# Concatenate Swift source files per target into separate .swift files
# Output: One .swift file per target in the output directory

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$SCRIPT_DIR/Sources"
OUTPUT_DIR="$SCRIPT_DIR/concatenated"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Define targets (all source directories)
TARGETS=(
    "IO Primitives"
    "IO Blocking"
    "IO Blocking Threads"
    "IO"
    "IO NonBlocking Primitives"
    "IO NonBlocking Driver"
    "IO NonBlocking Kqueue"
    "IO NonBlocking"
)

for target in "${TARGETS[@]}"; do
    target_dir="$SOURCES_DIR/$target"
    # Convert target name to filename (replace spaces with hyphens)
    output_filename="${target// /-}.swift"
    output_file="$OUTPUT_DIR/$output_filename"

    if [[ -d "$target_dir" ]]; then
        # Clear/create the output file
        > "$output_file"

        echo "// Concatenated sources for target: $target" >> "$output_file"
        echo "// Generated on: $(date)" >> "$output_file"
        echo "" >> "$output_file"

        # Find all .swift files in the target directory and concatenate them
        while IFS= read -r -d '' swift_file; do
            filename=$(basename "$swift_file")
            echo "" >> "$output_file"
            echo "// ----------------------------------------------------------------------------" >> "$output_file"
            echo "// File: $filename" >> "$output_file"
            echo "// ----------------------------------------------------------------------------" >> "$output_file"
            echo "" >> "$output_file"
            cat "$swift_file" >> "$output_file"
            echo "" >> "$output_file"
        done < <(find "$target_dir" -name "*.swift" -type f -print0 | sort -z)

        echo "Created: $output_file"
    else
        echo "Warning: Target directory not found: $target_dir"
    fi
done

echo ""
echo "Output files written to: $OUTPUT_DIR"
