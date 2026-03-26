chmod +x zoom-cli.sh
./zoom-cli.sh refresh-csrf   # gets fresh CSRF token
./zoom-cli.sh list            # list meetings
./zoom-cli.sh create --topic "My Standup" --date 03/10/2026 --time 9:00 --ampm AM --duration 0 --duration-min 30
./zoom-cli.sh create --topic "Weekly Sync" --recurring --recurrence-type 2 --recurrence-interval 1
./zoom-cli.sh delete <meeting_id>
