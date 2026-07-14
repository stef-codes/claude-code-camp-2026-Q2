import { createContext, useContext, useState, useEffect, type ReactNode } from "react";

export interface Visit {
  roomId: number;
  roomName: string;
  visitedAt: Date;
  visitor?: string; // "you" for local visits; agents/others come from visits.json
  note?: string;
}

interface VisitsState {
  visits: Visit[];
  addVisit: (roomId: number, roomName: string) => void;
  hasVisited: (roomId: number) => boolean;
  clearVisits: () => void;
}

const VisitsContext = createContext<VisitsState | null>(null);

const STORAGE_KEY = "circlemud-visits";

function reviveDates(raw: any[]): Visit[] {
  return raw.map((v) => ({ ...v, visitedAt: new Date(v.visitedAt) }));
}

export function VisitsProvider({ children }: { children: ReactNode }) {
  // Visits made in this browser (persisted to localStorage).
  const [localVisits, setLocalVisits] = useState<Visit[]>([]);
  // Visits recorded outside the browser (e.g. by an agent) in public/data/visits.json.
  const [sharedVisits, setSharedVisits] = useState<Visit[]>([]);

  useEffect(() => {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored) {
      try {
        setLocalVisits(reviveDates(JSON.parse(stored)));
      } catch (e) {
        console.error("Failed to load visits from localStorage", e);
      }
    }

    fetch("/data/visits.json")
      .then((res) => (res.ok ? res.json() : []))
      .then((raw) => setSharedVisits(reviveDates(raw)))
      .catch(() => setSharedVisits([]));
  }, []);

  useEffect(() => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(localVisits));
  }, [localVisits]);

  const visits = [...sharedVisits, ...localVisits];

  const addVisit = (roomId: number, roomName: string) => {
    setLocalVisits((prev) => [
      ...prev,
      { roomId, roomName, visitedAt: new Date(), visitor: "you" },
    ]);
  };

  const hasVisited = (roomId: number) => visits.some((v) => v.roomId === roomId);

  // Only clears browser-local visits; shared visits live in visits.json.
  const clearVisits = () => setLocalVisits([]);

  return (
    <VisitsContext.Provider value={{ visits, addVisit, hasVisited, clearVisits }}>
      {children}
    </VisitsContext.Provider>
  );
}

export function useVisits(): VisitsState {
  const ctx = useContext(VisitsContext);
  if (!ctx) throw new Error("useVisits must be used within a VisitsProvider");
  return ctx;
}
