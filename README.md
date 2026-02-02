# Scotland Yard — Godot Game Client

A **Godot 4** client for the classic board game **Scotland Yard**, powered by Solana and a REST API. One player is **Mr. X** (hidden); up to three others are **Detectives** (visible). Mr. X’s position is encrypted on-chain; detectives try to catch him before 24 rounds.

---

## Game Overview

- **Mr. X** (1 player): Moves secretly; position is encrypted on Solana. Must reveal at fixed rounds (e.g. 3, 8, 13, 18, 24).
- **Detectives** (2–3 players): Move on the London board (taxi, bus, underground, ferry). Win by landing on Mr. X’s position.
- **Mr. X wins** by surviving 24 rounds without being caught.

The client supports **web** (Phantom wallet, message signing) and **desktop** (test mode, no wallet).

---

## Repository Links

| Component        | Repository |
|-----------------|------------|
| **APIs**        | [https://github.com/shrooms08/scotland-yard-api-.git](https://github.com/shrooms08/scotland-yard-api-.git) |
| **Solana Program** | [https://github.com/shrooms08/scotland-yard-solana-program.git](https://github.com/shrooms08/scotland-yard-solana-program.git) |
| **This client** | Scotland Yard Godot (this repo) |

The API bridges this Godot client to the Solana Scotland Yard program (create game, join, move Mr. X, move detectives, reveal).

---

## Requirements

- **Godot 4.5** (or compatible 4.x)
- **Scotland Yard API** running (see API repo). Default base URL: `http://localhost:3000`
- **Web export**: Phantom (or compatible) wallet
- **Desktop**: No wallet needed; use API with `TEST_MODE=true` or `HACKATHON_DEMO=true`

---

## Setup & Run

1. **Clone and open in Godot**
   - Open the project with Godot 4 (e.g. open `project.godot`).

2. **Start the API**
   - From the [scotland-yard-api](https://github.com/shrooms08/scotland-yard-api-.git) repo:
   ```bash
   cd scotland-yard-api
   npm install
   TEST_MODE=true npm run dev
   ```
   - Or for hackathon/demo: `HACKATHON_DEMO=true npm run dev` (see API README).

3. **Run the game**
   - **Editor**: Press Play (F5). Desktop build uses test endpoints; web build uses Phantom.
   - **API URL**: If the API is not on `localhost:3000`, set the base URL in the client (e.g. in `Script/manager/solana_client.gd`: `BASE_URL` or `set_base_url()`).

4. **Web export**
   - Export as HTML5. Ensure the API is reachable from the browser (same host or CORS allowed). Connect Phantom when prompted.

---

## Flow

1. **Main menu**: “Connect Wallet” → on web, connect Phantom; on desktop, a test wallet is used. Then “Enter Game”.
2. **Lobby**
   - **Create Game**: Play as Mr. X. Choose number of detectives (2–3). Client creates the game via API; you get a **Game PDA** to share.
   - **Join Game**: Paste the Game PDA and join as a detective (starting position is chosen for you).
3. **Game board**: Turn-based moves — Mr. X moves (encrypted), then each detective. At reveal rounds, Mr. X’s position is shown. First to catch Mr. X wins (detectives); if Mr. X survives 24 rounds, Mr. X wins.

---

## Project Structure (Godot)

```
scotland-yard-godot/
├── project.godot
├── Scene/           # main_menu, lobby, game_board, board_node
├── Script/          # UI and game logic
│   └── manager/     # game_manager.gd, solana_client.gd, audio_manager.gd
├── Program/         # scotland_yard_program.json (IDL for Solana)
├── Asset/           # Fonts, images, sounds
└── SolanaSDK/       # Godot Solana/Anchor integration
```

---

## Configuration

- **API base URL**: In `Script/manager/solana_client.gd`, `BASE_URL` defaults to `http://localhost:3000`. Use `GlobalSolanaClient.set_base_url(url)` if your API runs elsewhere.
- **Web**: The client uses the API’s intent flow (Phantom signs a message; server submits the Solana transaction).
- **Desktop**: The client uses test endpoints (`create-test`, `join-test`, move-test, etc.); the API signs with its keypair (`~/.config/solana/id.json` when `TEST_MODE=true`).

---

## Credits & Submission

- **Game**: Scotland Yard (board game)
- **Stack**: Godot 4, Solana (devnet), REST API, encrypted Mr. X position on-chain
- **Repositories**:
  - APIs: [scotland-yard-api](https://github.com/shrooms08/scotland-yard-api-.git)
  - Solana Program: [scotland-yard-solana-program](https://github.com/shrooms08/scotland-yard-solana-program.git)
