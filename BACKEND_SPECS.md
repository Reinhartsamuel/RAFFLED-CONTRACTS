# Backend & Infrastructure Specification

## Data Layer (Indexing)
- **Tool**: Ponder or Envio (Event-driven indexing).
- **Entities**:
  - `Raffle`: (ID, Host, Prize, Expiry, Status, Winner).
  - `Participant`: (Address, RaffleID, TicketCount).
- **Logic**: Index `RaffleCreated`, `TicketPurchased`, and `WinnerPicked` events to provide a high-speed GraphQL API for the frontend.

## Authentication & API
- **Protocol**: SIWE (Sign-In with Ethereum).
- **Metadata Storage**: Use PostgreSQL to store off-chain data (Raffle name, description, images) linked by `raffleId`.
- **Validation**: API must verify the user owns the `host` address via SIWE before allowing metadata updates.

## Notifications & UX
- **Webhooks**: Use Alchemy Notify to trigger:
  - "Raffle Ended" alerts.
  - "You Won!" push notifications/emails.
- **The Manual Trigger**: Frontend should provide a "Manual Resolve" button that calls `performUpkeep` directly if Automation is delayed, allowing users to pay gas for faster resolution.
