#!/usr/bin/env python3
import sys
import os
import argparse
import time
import json
import shutil

# Ensure we can import the local grablytic_engine module
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from grablytic_engine import (
    set_paths,
    bootstrap,
    start_download,
    cancel_download,
    get_formats,
)
from grablytic_engine.downloader import _active_downloads, _downloads_lock


def main():
    parser = argparse.ArgumentParser(description="Grablytic CLI Engine Test Tool")
    parser.add_argument("url", help="The media URL to download or inspect")
    parser.add_argument("--info-only", action="store_true", help="Only get available formats without downloading")
    parser.add_argument("--output-dir", default=".", help="Directory to save the download (default: current directory)")
    parser.add_argument("--audio-only", action="store_true", help="Download audio only")
    parser.add_argument("--container", default="mkv", choices=["mkv", "mp4", "webm"], help="Preferred video container")
    parser.add_argument("--audio-format", default="opus", choices=["opus", "flac", "m4a", "mp3"], help="Preferred audio format")
    
    args = parser.parse_args()
    
    # Locate ffmpeg
    ffmpeg_path = shutil.which("ffmpeg")
    if not ffmpeg_path:
        print("Warning: ffmpeg not found in PATH. Post-processing might fail if needed.", file=sys.stderr)
        ffmpeg_path = "ffmpeg"  # Fallback to literal name
        
    # Set paths
    data_dir = os.path.expanduser("~/.local/share/grablytic")
    cache_dir = os.path.expanduser("~/.cache/grablytic")
    os.makedirs(data_dir, exist_ok=True)
    os.makedirs(cache_dir, exist_ok=True)
    os.makedirs(args.output_dir, exist_ok=True)
    
    set_paths(
        data_dir=data_dir,
        output_dir=os.path.abspath(args.output_dir),
        ffmpeg_path=ffmpeg_path,
        cache_dir=cache_dir
    )
    
    # Bootstrap
    print("Bootstrapping engine...")
    boot_res = bootstrap()
    if not boot_res.get("success"):
        print(f"Error: Bootstrap failed: {boot_res.get('error_message')}", file=sys.stderr)
        sys.exit(1)
        
    print(f"Engine bootstrapped successfully. yt-dlp version: {boot_res.get('yt_dlp_version')}")
    
    if args.info_only:
        print(f"\nFetching formats for: {args.url}\n")
        formats_res = get_formats(args.url)
        if not formats_res.get("success"):
            print(f"Error: Failed to fetch formats: {formats_res.get('error_message')}", file=sys.stderr)
            sys.exit(1)
        print(json.dumps(formats_res, indent=2))
        return
        
    # Start download
    config = {
        "audio_only": args.audio_only,
        "container": args.container,
        "audio_format": args.audio_format,
        "embedthumbnail": True,
    }
    
    download_id = "cli_test_download"
    print(f"Starting download of {args.url} to {os.path.abspath(args.output_dir)}...")
    
    start_res = start_download(
        url=args.url,
        download_id=download_id,
        config=config
    )
    
    if not start_res.get("success"):
        print(f"Error starting download: {start_res.get('error_message')}", file=sys.stderr)
        sys.exit(1)
        
    # Monitor queues
    try:
        while True:
            # Check if download is still active
            with _downloads_lock:
                info = _active_downloads.get(download_id)
                if not info:
                    break
                prog_q = info.get("progress_queue")
                res_q = info.get("result_queue")
                
            # Process progress
            if prog_q:
                while not prog_q.empty():
                    event_str = prog_q.get_nowait()
                    event = json.loads(event_str)
                    evt_type = event.get("event")
                    
                    if evt_type == "downloading":
                        downloaded = event.get("downloaded_bytes", 0)
                        total = event.get("total_bytes", 0)
                        speed = event.get("speed", 0)
                        eta = event.get("eta", 0)
                        
                        # Format speed
                        if speed is None:
                            speed = 0
                        if speed > 1024 * 1024:
                            speed_str = f"{speed / (1024 * 1024):.2f} MB/s"
                        elif speed > 1024:
                            speed_str = f"{speed / 1024:.2f} KB/s"
                        else:
                            speed_str = f"{speed} B/s"
                            
                        # Format progress percentage
                        percent = 0.0
                        if total > 0:
                            percent = (downloaded / total) * 100
                            
                        # Format downloaded/total
                        dl_mb = downloaded / (1024 * 1024)
                        tot_mb = total / (1024 * 1024)
                        
                        # Print status line
                        sys.stdout.write(f"\rProgress: {percent:.1f}% ({dl_mb:.1f}/{tot_mb:.1f} MB) | Speed: {speed_str} | ETA: {eta}s   ")
                        sys.stdout.flush()
                    elif evt_type == "postprocessing":
                        sys.stdout.write(f"\n[Post-Processing] {event.get('stage_label', 'Processing...')}\n")
                        sys.stdout.flush()
                        
            # Process results
            if res_q:
                while not res_q.empty():
                    res = res_q.get_nowait()
                    if res.get("success"):
                        print("\nDownload finished successfully!")
                        return
                    else:
                        print(f"\nDownload failed: {res.get('error_message')}")
                        sys.exit(1)
                        
            time.sleep(0.1)
    except KeyboardInterrupt:
        print("\nCancelling download...")
        cancel_download(download_id)
        print("Cancelled.")


if __name__ == "__main__":
    main()
