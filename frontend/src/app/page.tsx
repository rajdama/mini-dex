"use client";

import dynamic from "next/dynamic";

// The app depends on the wallet and the current time, so it renders only in the browser.
const App = dynamic(() => import("@/components/App"), {
  ssr: false,
  loading: () => <div className="container" style={{ padding: 40, color: "#8b93a7" }}>Loading…</div>,
});

export default function Page() {
  return <App />;
}
