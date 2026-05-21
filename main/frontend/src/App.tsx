import { Routes, Route } from "react-router-dom";
import { GrainOverlay } from "@/components/GrainOverlay";
import { ErrorBoundary } from "@/components/ErrorBoundary";
import Chat from "@/pages/Chat";
import Tts from "@/pages/Tts";
import Login from "@/pages/Login";
import Register from "@/pages/Register";
import NotFound from "@/pages/NotFound";
import Diagnostics from "@/pages/Diagnostics";

export default function App() {
  return (
    <ErrorBoundary>
      <Routes>
        <Route path="/" element={<Login />} />
        <Route path="/chat" element={<Chat />} />
        <Route path="/tts" element={<Tts />} />
        <Route path="/register" element={<Register />} />
        <Route path="/diagnostics" element={<Diagnostics />} />
        <Route path="*" element={<NotFound />} />
      </Routes>
      <GrainOverlay />
    </ErrorBoundary>
  );
}
