import { ShortenForm } from './components/ShortenForm';

function App() {
  return (
    <div className="min-h-screen bg-gray-50 flex items-center justify-center p-4">
      <div className="w-full max-w-xl">
        <div className="text-center mb-8">
          <h1 className="text-4xl font-bold text-gray-900 tracking-tight">URL Shortener</h1>
          <p className="mt-2 text-gray-500">Paste a long URL and get a short link instantly.</p>
        </div>
        <ShortenForm />
      </div>
    </div>
  );
}

export default App;
