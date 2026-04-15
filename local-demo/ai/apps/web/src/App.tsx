import { Link, NavLink, Route, Routes } from 'react-router-dom';
import Regression from './pages/Regression';
import Hotspots from './pages/Hotspots';
import Incidents from './pages/Incidents';
import Chat from './pages/Chat';

const navCls = ({ isActive }: { isActive: boolean }) =>
  `px-3 py-2 rounded hover:bg-neutral-800 ${isActive ? 'bg-neutral-800 text-white' : 'text-neutral-400'}`;

export default function App() {
  return (
    <div className="min-h-screen flex">
      <aside className="w-56 border-r border-neutral-800 p-4 space-y-2">
        <Link to="/" className="block text-xl font-semibold text-white mb-4">Pyroscope AI</Link>
        <nav className="flex flex-col gap-1 text-sm">
          <NavLink to="/regression" className={navCls}>Regression</NavLink>
          <NavLink to="/hotspots" className={navCls}>Hotspots</NavLink>
          <NavLink to="/incidents" className={navCls}>Incidents</NavLink>
          <NavLink to="/chat" className={navCls}>Chat</NavLink>
        </nav>
      </aside>
      <main className="flex-1 p-6 overflow-auto">
        <Routes>
          <Route path="/" element={<Hotspots />} />
          <Route path="/regression" element={<Regression />} />
          <Route path="/hotspots" element={<Hotspots />} />
          <Route path="/incidents" element={<Incidents />} />
          <Route path="/incidents/:id" element={<Incidents />} />
          <Route path="/chat" element={<Chat />} />
        </Routes>
      </main>
    </div>
  );
}
