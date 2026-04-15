# Reference — UI pages

React SPA at `/`, served by nginx. Nginx reverse-proxies `/api/*` to the
FastAPI container — so the SPA knows nothing about backend ports.

| page          | route           | data sources                                    |
|---------------|-----------------|-------------------------------------------------|
| Hotspots      | `/hotspots`, `/` | `GET /hotspots/leaderboard`                     |
| Regression    | `/regression`   | `GET /profiles/diff`, `GET /regressions`        |
| Incidents     | `/incidents`    | `GET /incidents`, `GET /incidents/{id}`, `POST /similarity` |
| Chat          | `/chat`         | `POST /chat` (SSE)                              |

## Components

- `components/Flame.tsx` — wraps `react-flame-graph`; converts Pyroscope
  flamebearer format → tree.
- `api/client.ts` — TanStack Query hooks + SSE reader.

## Tech stack

| piece          | choice                             | why                                   |
|----------------|------------------------------------|---------------------------------------|
| bundler        | Vite 5                             | fast, no config                       |
| framework      | React 18 + TypeScript              | mainstream, typed                     |
| routing        | react-router 6                     | SPA navigation                        |
| data fetching  | TanStack Query 5                   | caches, dedupes, background refetch   |
| styles         | Tailwind                           | utility classes, no runtime CSS       |
| flame graph    | `react-flame-graph`                | only React-native flame library       |
| charts         | Recharts (available, unused)       | for future trend charts               |
