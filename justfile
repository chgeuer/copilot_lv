# Start the Phoenix server (visible output, logs to run.log)
start:
    #!/usr/bin/env bash
    SNAME="$(basename "$(pwd)")"
    export PORT="${PORT:-$(phx-port)}"
    export ELIXIR_ERL_OPTIONS="-sname $SNAME -setcookie devcookie"
    exec mix phx.server 2>&1 | tee run.log

# Start the Phoenix server in background (logs to run.log only)
start-bg:
    #!/usr/bin/env bash
    SNAME="$(basename "$(pwd)")"
    export PORT="${PORT:-$(phx-port)}"
    export ELIXIR_ERL_OPTIONS="-sname $SNAME -setcookie devcookie"
    exec mix phx.server > run.log 2>&1

# Open the app in a browser (starts the server if not running)
open:
    #!/usr/bin/env bash
    SNAME="$(basename "$(pwd)")"
    if ! scripts/dev_node.sh status > /dev/null 2>&1; then
        echo "Node $SNAME not running, starting in background..."
        export PORT="${PORT:-$(phx-port)}"
        export ELIXIR_ERL_OPTIONS="-sname $SNAME -setcookie devcookie"
        mix phx.server > run.log 2>&1 &
        scripts/dev_node.sh await
    fi
    phx-port open

# Stop the running BEAM node gracefully
stop:
    scripts/dev_node.sh rpc "System.halt()"

# Check if the BEAM node is running
status:
    scripts/dev_node.sh status

# Execute an expression on the running BEAM node
rpc EXPR:
    scripts/dev_node.sh rpc "{{EXPR}}"
