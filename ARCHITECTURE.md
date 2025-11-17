# Server Architecture

1. **Main Thread**: Accepts connections and handles IPC requests, responses, and
   notifications. It checks each PTY and sends screen updates to connected
clients. It also writes to each PTY as needed (keyboard, mouse, etc).
2. **PTY Threads**: Each PTY runs in its own thread. This thread does blocking
   reads from the underlying PTY and processes VT sequences, persisting local
state. It also handles automatic responses to certain VT queries (e.g. Device
Attributes) by writing directly to the PTY.
3. **Event-Oriented Frame Scheduler**:
   - **Per-Pty Pipe**: Each `Pty` owns a non-blocking pipe pair. The
   read end is registered with the main thread's event loop; the write end is
   used by the PTY thread.
   - **Producer (PTY Thread)**: After updating the terminal state, it writes a
   single byte to the pipe. `EAGAIN` is ignored (signal already pending).
   - **Consumer (Main Thread)**:
     - **On Signal**: Drains the pipe. If enough time has passed since
     `last_render_time`, renders immediately. Otherwise, if no timer is pending,
     schedules one for the remaining duration.
     - **On Timer**: Renders immediately and updates `last_render_time`.

# Client Architecture

1. **Main Thread (Input)**:
   - Responsible for initializing the UI (raw mode, entering alternate screen) and
   establishing the connection to the Server.
   - Spawns the **Socket Thread**.
   - **Loop**: Performs blocking reads on the local PTY/TTY (Input).
   - Writes input/requests to the Server Socket.
   - Handles `SIGWINCH` (or delegates to a signal handler) by sending a resize
   request to the server.

2. **Socket Thread (Output/Renderer)**:
   - **Loop**: Reads messages from the Server Socket.
   - Updates the local screen state based on Server messages.
   - Paints the screen to the local terminal (`stdout`).
   - Handles server-side events (like `Resize` notifications) to keep the
   renderer in sync.

3. **Synchronization Flow**:
   - **Resize**: 
     1. Client detects resize -> Sends request to Server.
     2. Server resizes internal PTY -> Sends resize event to Client.
     3. Socket Thread receives event -> Updates renderer state -> Repaints.
   - **Shutdown**:
     - **User Quit**: Input thread sends close request -> Server closes
     connection -> Socket thread detects close -> Exits process.
     - **Server Quit**: Socket thread detects disconnect -> Exits process.

# Client Data Model

1. **Double Buffering**:
   - Each **Surface** maintains two `Screen` buffers:
     - **Front Buffer**: Represents the stable state for the current frame.
     - **Back Buffer**: Receives incremental updates from the server.
   - **Update Cycle**:
     1. **Receive**: Messages from the server update the **Back Buffer**.
     2. **Frame Boundary**: When a frame is ready, the Surface copies/swaps
        Back -> Front.
     3. **Render**: The application draws the **Front Buffer** into the Vaxis
        virtual screen.
     4. **Vaxis**: Handles the final diffing and generation of VT sequences to
        update the physical terminal.

2. **Surfaces**:

   - A **Surface** represents the state of a single remote PTY.
   - Each Surface owns its own pair of Front/Back buffers.
   - The Client manages a collection of Surfaces (one per connected PTY).
