import { useVisits } from "../data/useVisits";
import { RoomLink } from "../components/links";

export function Visits() {
  const { visits, clearVisits } = useVisits();

  const sortedVisits = [...visits].sort(
    (a, b) => new Date(b.visitedAt).getTime() - new Date(a.visitedAt).getTime()
  );

  return (
    <article className="detail">
      <header>
        <h1>Visited Locations</h1>
        <div className="subhead">
          <span>{visits.length} location{visits.length !== 1 ? "s" : ""} visited</span>
        </div>
      </header>

      {visits.length === 0 ? (
        <section>
          <p className="muted">You haven't visited any locations yet. Start exploring!</p>
        </section>
      ) : (
        <>
          <section>
            <table>
              <thead>
                <tr>
                  <th>Room</th>
                  <th>Visitor</th>
                  <th>Visited At</th>
                  <th>Note</th>
                </tr>
              </thead>
              <tbody>
                {sortedVisits.map((visit, i) => (
                  <tr key={i}>
                    <td>
                      <RoomLink id={visit.roomId} />
                    </td>
                    <td>{visit.visitor ?? "you"}</td>
                    <td className="muted">{visit.visitedAt.toLocaleString()}</td>
                    <td className="muted">{visit.note ?? "—"}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>

          <section>
            <button
              onClick={() => {
                if (window.confirm("Clear all visits?")) {
                  clearVisits();
                }
              }}
              style={{
                padding: "8px 16px",
                backgroundColor: "#dc2626",
                color: "white",
                border: "none",
                borderRadius: "4px",
                cursor: "pointer",
              }}
            >
              Clear Visits
            </button>
          </section>
        </>
      )}
    </article>
  );
}
