import { useState } from 'react';
import type { FormEvent } from 'react';
import type { ShortenRequest, ShortenResponse } from '@url-shortener/types';

type State =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'success'; shortUrl: string }
  | { status: 'error'; message: string };

const API_BASE = import.meta.env.VITE_API_URL ?? '';

export function ShortenForm() {
  const [longUrl, setLongUrl] = useState('');
  const [state, setState] = useState<State>({ status: 'idle' });
  const [copied, setCopied] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setState({ status: 'loading' });
    setCopied(false);

    try {
      const body: ShortenRequest = { longUrl };
      const res = await fetch(`${API_BASE}/api/v1/data/shorten`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });

      if (!res.ok) {
        const err = await res.json().catch(() => ({}));
        const msg = Array.isArray(err.message) ? err.message.join(', ') : (err.message ?? 'Something went wrong');
        setState({ status: 'error', message: msg });
        return;
      }

      const data: ShortenResponse = await res.json();
      setState({ status: 'success', shortUrl: data.shortUrl });
    } catch {
      setState({ status: 'error', message: 'Network error — is the API running?' });
    }
  }

  async function handleCopy(url: string) {
    await navigator.clipboard.writeText(url);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <div className="bg-white rounded-2xl shadow-md p-6 space-y-4">
      <form onSubmit={handleSubmit} className="flex gap-2">
        <input
          type="url"
          value={longUrl}
          onChange={(e) => setLongUrl(e.target.value)}
          placeholder="https://example.com/very/long/url"
          required
          className="flex-1 rounded-lg border border-gray-300 px-4 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent"
        />
        <button
          type="submit"
          disabled={state.status === 'loading'}
          className="rounded-lg bg-indigo-600 px-5 py-2 text-sm font-semibold text-white hover:bg-indigo-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
        >
          {state.status === 'loading' ? 'Shortening…' : 'Shorten'}
        </button>
      </form>

      {state.status === 'success' && (
        <div className="flex items-center justify-between rounded-lg bg-indigo-50 border border-indigo-200 px-4 py-3 gap-3">
          <a
            href={state.shortUrl}
            target="_blank"
            rel="noopener noreferrer"
            className="text-sm font-medium text-indigo-700 truncate hover:underline"
          >
            {state.shortUrl}
          </a>
          <button
            onClick={() => handleCopy(state.shortUrl)}
            className="shrink-0 text-xs font-semibold text-indigo-600 hover:text-indigo-800 transition-colors"
          >
            {copied ? 'Copied!' : 'Copy'}
          </button>
        </div>
      )}

      {state.status === 'error' && (
        <p className="text-sm text-red-600 rounded-lg bg-red-50 border border-red-200 px-4 py-3">
          {state.message}
        </p>
      )}
    </div>
  );
}
