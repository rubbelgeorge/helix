import React, { useState, useEffect, useRef, useCallback } from 'react';
import { createRoot } from 'react-dom/client';
import {
  Play, Pause, Stop, SkipBack, SkipForward, SpeakerLow, SpeakerHigh, MusicNotes, Queue, Books, Link as LinkIcon,
  DotsThree, X, ArrowLeft, ArrowRight, Shuffle, MagnifyingGlass, Moon, Sun, ArrowLineUp, ArrowUp, ArrowDown,
  Trash, PlayCircle, ListPlus, Plus, WifiSlash, CaretDown, MicrophoneStage, VinylRecord, UserCircle, Stack, House, SquaresFour,
} from '@phosphor-icons/react';
import '@fontsource/geist/latin-400.css';
import '@fontsource/geist/latin-500.css';
import '@fontsource/geist/latin-600.css';
import './style.css';
import { markSVG } from './helix.js';

// ---------- API ----------

async function request(path, body, signal) {
  const response = await fetch(path, {
    method: body ? 'POST' : 'GET', credentials: 'same-origin', cache: 'no-store', signal,
    headers: body ? { 'Content-Type': 'application/json', 'X-AM-Remote': '1' } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  let data = {};
  try { data = await response.json(); } catch { /* empty body */ }
  if (!response.ok) {
    const error = new Error(data.error || 'The connection to the Mac failed.');
    error.status = response.status; throw error;
  }
  return data;
}
const time = value => {
  const s = Math.max(0, Math.floor(value || 0));
  return s >= 3600 ? `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`
    : `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
};
const kHz = rate => `${String(rate / 1000)} kHz`;
const itemPayload = item => ({ catalogID: item.catalogID, title: item.title, artist: item.artist, artwork: item.artwork });

function useMediaQuery(query) {
  const [matches, setMatches] = useState(() => matchMedia(query).matches);
  useEffect(() => { const list = matchMedia(query); const update = () => setMatches(list.matches); list.addEventListener('change', update); return () => list.removeEventListener('change', update); }, [query]);
  return matches;
}

// ---------- Small building blocks ----------

function Cover({ src, size = 'sm', alt = '' }) {
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [src]);
  return <div className={`cover cover-${size}`}>
    {src && !failed ? <img src={src} alt={alt} loading={size === 'xl' ? 'eager' : 'lazy'} decoding="async" onError={() => setFailed(true)} />
      : <MusicNotes weight="light" aria-hidden="true" />}
  </div>;
}
function IconButton({ label, children, className = '', ...props }) {
  return <button type="button" className={`icon-button ${className}`} aria-label={label} title={label} {...props}>{children}</button>;
}
function Range({ value, max, onChange, onCommit, label, disabled, className = '' }) {
  const fill = max > 0 ? Math.min(100, (value / max) * 100) : 0;
  return <input type="range" aria-label={label} className={`range ${className}`} min="0" max={max || 1} step="any" value={value} disabled={disabled}
    style={{ '--fill': `${fill}%` }}
    onChange={e => onChange(Number(e.target.value))}
    onPointerUp={e => onCommit(Number(e.currentTarget.value))}
    onKeyUp={e => { if (['ArrowRight', 'ArrowLeft', 'ArrowUp', 'ArrowDown', 'Home', 'End', 'PageUp', 'PageDown'].includes(e.key)) onCommit(Number(e.currentTarget.value)); }} />;
}

/// Bottom sheet on phones, centered dialog on wide screens. Native <dialog> for focus handling.
function Sheet({ open, onClose, title, children }) {
  const ref = useRef(null);
  useEffect(() => {
    const dialog = ref.current; if (!dialog) return;
    if (open && !dialog.open) dialog.showModal();
    if (!open && dialog.open) dialog.close();
  }, [open]);
  return <dialog ref={ref} className="sheet" onClose={onClose} onClick={e => { if (e.target === ref.current) onClose(); }} aria-label={title}>
    {open && <div className="sheet-body">{children}</div>}
  </dialog>;
}
function SheetHeader({ item, subtitle }) {
  return <div className="sheet-header"><Cover src={item.artwork} /><div className="min-w-0"><strong>{item.title}</strong><span>{subtitle ?? item.artist}</span></div></div>;
}
function SheetAction({ icon, children, onClick, destructive, disabled }) {
  return <button type="button" className={`sheet-action ${destructive ? 'destructive' : ''}`} onClick={onClick} disabled={disabled}>{icon}<span>{children}</span></button>;
}

// ---------- App ----------

function App() {
  const [theme, setTheme] = useState(() => { try { return localStorage.getItem('am-theme') || 'system'; } catch { return 'system'; } });
  const systemDark = useMediaQuery('(prefers-color-scheme: dark)');
  const dark = theme === 'dark' || (theme === 'system' && systemDark);
  const wide = useMediaQuery('(min-width: 1024px)');
  const [state, setState] = useState(null);
  const [receivedAt, setReceivedAt] = useState(0);
  const [online, setOnline] = useState(true);
  const [tab, setTab] = useState('now');
  // Where the full player returns to on phones.
  const [lastTab, setLastTab] = useState('home');
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [linkOpen, setLinkOpen] = useState(false);
  // Album, playlist and artist pages opened on top of the library and search tabs.
  const [stacks, setStacks] = useState({ home: [], new: [], library: [], search: [] });
  const [searchTerm, setSearchTerm] = useState('');
  const pending = useRef(false), sequence = useRef(0);

  useEffect(() => {
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
    try { localStorage.setItem('am-theme', theme); } catch { /* private mode */ }
    document.querySelector('meta[name="theme-color"]').content = dark ? '#141416' : '#f5f5f7';
  }, [dark, theme]);

  const accept = useCallback(next => { setState(next); setReceivedAt(performance.now()); setOnline(true); }, []);

  useEffect(() => {
    let active = true, timer; const abort = new AbortController();
    async function poll() {
      if (!pending.current) {
        const serial = ++sequence.current;
        try { const next = await request('/api/state', undefined, abort.signal); if (active && serial === sequence.current) accept(next); }
        catch (e) { if (active && e.name !== 'AbortError') setOnline(false); }
      }
      if (active) timer = setTimeout(poll, document.hidden ? 5000 : 1500);
    }
    const wake = () => { if (!document.hidden) { clearTimeout(timer); poll(); } };
    poll(); document.addEventListener('visibilitychange', wake);
    return () => { active = false; clearTimeout(timer); abort.abort(); document.removeEventListener('visibilitychange', wake); };
  }, [accept]);

  useEffect(() => { if (!notice) return; const t = setTimeout(() => setNotice(''), 2400); return () => clearTimeout(t); }, [notice]);
  useEffect(() => { if (!error) return; const t = setTimeout(() => setError(''), 6000); return () => clearTimeout(t); }, [error]);

  const command = useCallback(async (action, fields = {}, success) => {
    if (pending.current) return false;
    pending.current = true; sequence.current++; setError('');
    try { accept(await request('/api/command', { action, ...fields })); if (success) setNotice(success); return true; }
    catch (e) { setError(e.message); return false; }
    finally { pending.current = false; }
  }, [accept]);

  const cycleTheme = () => setTheme(dark ? 'light' : 'dark');

  const view = wide && tab === 'now' ? 'home' : tab;
  // Pages open in the current browsing tab; from Now Playing or the queue they open in search.
  const browseTabs = ['home', 'new', 'library', 'search'];
  const browseTab = browseTabs.includes(view) ? view : 'search';
  const selectTab = id => {
    // Tapping the active browsing tab again returns to its start page, as on iOS.
    if (tab === id && stacks[id]?.length) setStacks(current => ({ ...current, [id]: [] }));
    if (id !== 'now') setLastTab(id);
    setTab(id); window.scrollTo({ top: 0 });
  };
  const push = useCallback(route => {
    setStacks(current => ({ ...current, [browseTab]: [...current[browseTab], route] }));
    setTab(browseTab); window.scrollTo({ top: 0 });
  }, [browseTab]);
  const nav = {
    push,
    pop: () => { setStacks(current => ({ ...current, [view]: (current[view] || []).slice(0, -1) })); window.scrollTo({ top: 0 }); },
    openCollection: item => push({ type: 'collection', item }),
    openArtist: (id, name) => push({ type: 'artist', id, name }),
    openCategory: category => push({ type: 'category', ...category }),
    album: async songID => {
      try { const links = await request(`/api/song-links?id=${encodeURIComponent(songID)}`); links.album ? push({ type: 'collection', item: links.album }) : setError('No album found for this song.'); }
      catch (e) { setError(e.message); }
    },
    artist: async songID => {
      try { const links = await request(`/api/song-links?id=${encodeURIComponent(songID)}`); const a = links.artists?.[0]; a ? push({ type: 'artist', id: a.id, name: a.name }) : setError('No artist found for this song.'); }
      catch (e) { setError(e.message); }
    },
    albumArtist: async item => {
      try { const r = await request(`/api/album-artists?id=${encodeURIComponent(item.id)}&type=${encodeURIComponent(item.type)}`); const a = r.artists?.[0]; a ? push({ type: 'artist', id: a.id, name: a.name }) : setError('No artist found for this album.'); }
      catch (e) { setError(e.message); }
    },
  };

  if (!state) return <Connecting online={online} />;

  const ready = online && state?.ready;
  const shared = { state, command, ready, notify: setNotice, nav };
  const stack = stacks[view] || [];
  const route = stack[stack.length - 1];
  const paneLabel = { home: 'Home', new: 'New', queue: 'Playing Next', library: 'Library', search: 'Search' }[view] || 'Library';
  const tabs = [['home', 'Home', <House key="i" />], ['new', 'New', <SquaresFour key="i" />], ['queue', 'Playing Next', <Queue key="i" />],
    ['library', 'Library', <Books key="i" />], ['search', 'Search', <MagnifyingGlass key="i" />]];

  return <div className="app">
    <Ambient src={state?.current?.artwork} />
    <header className="topbar">
      <div className="brand"><span className="brand-mark"><Mark width={22} height={13} /></span>Helix</div>
      <div className="topbar-actions">
        <IconButton label="Paste song link" onClick={() => setLinkOpen(true)} disabled={!ready}><LinkIcon /></IconButton>
        <IconButton label={dark ? 'Light appearance' : 'Dark appearance'} onClick={cycleTheme}>{dark ? <Sun /> : <Moon />}</IconButton>
      </div>
    </header>

    {(!online || (state && !state.ready) || error || state?.error) && <div className="banners">
      {!online && <p className="banner" role="status"><WifiSlash />Mac not reachable. Retrying automatically.</p>}
      {online && state && !state.ready && state.source !== 'airPlay' && <p className="banner" role="status">Sign in to Apple Music in the Mac app first.</p>}
      {(error || state?.error) && <p className="banner banner-error" role="alert">{error || state.error}</p>}
    </div>}

    <main className="layout">
      {(wide || tab === 'now') && <NowPlaying {...shared} receivedAt={receivedAt} onQueue={() => selectTab('queue')} onClose={wide ? null : () => setTab(lastTab)} />}
      {(wide || tab !== 'now') && <section className="pane" aria-label={paneLabel}>
        {wide && <div className="segmented" role="tablist">
          {tabs.map(([id, label]) => <button key={id} role="tab" aria-selected={view === id} onClick={() => selectTab(id)}>
            {label}{id === 'queue' && state?.queue?.length ? <span className="badge">{state.queue.length}</span> : null}
          </button>)}
        </div>}
        {route?.type === 'collection' ? <CollectionView key={`${route.item.type}-${route.item.id}`} collection={route.item} onBack={nav.pop} {...shared} />
          : route?.type === 'artist' ? <ArtistPane key={route.id} route={route} onBack={nav.pop} {...shared} />
          : route?.type === 'category' ? <EditorialPane key={`${route.kind}-${route.id}`} title={route.title} onBack={nav.pop}
              path={`/api/category?kind=${encodeURIComponent(route.kind)}&id=${encodeURIComponent(route.id)}&title=${encodeURIComponent(route.title)}`} {...shared} />
          : view === 'home' ? <EditorialPane key="home" title="Home" path="/api/home" {...shared} />
          : view === 'new' ? <EditorialPane key="new" title="New" path="/api/new" {...shared} />
          : view === 'queue' ? <QueuePane {...shared} onBrowse={() => selectTab('library')} />
          : view === 'search' ? <SearchPane term={searchTerm} onTerm={setSearchTerm} {...shared} />
          : <Library {...shared} />}
      </section>}
    </main>

    {!wide && tab !== 'now' && state?.current && <MiniPlayer state={state} command={command} ready={ready} onOpen={() => setTab('now')} />}
    {!wide && <nav className="tabbar" aria-label="Bereiche">
      {tabs.map(([id, label, icon]) =>
        <button key={id} aria-current={tab === id ? 'page' : undefined} onClick={() => selectTab(id)}>
          {React.cloneElement(icon, { weight: tab === id ? 'fill' : 'regular' })}<span>{label}</span>
          {id === 'queue' && state?.queue?.length > 0 && <span className="tab-badge" aria-label={`${state.queue.length} songs`}>{state.queue.length > 99 ? '99+' : state.queue.length}</span>}
        </button>)}
    </nav>}

    <LinkSheet open={linkOpen} onClose={() => setLinkOpen(false)} command={command} />
    <div className="toast-region" aria-live="polite">{notice && <div className="toast" key={notice}>{notice}</div>}</div>
  </div>;
}

/// The current cover, blurred, as a quiet backdrop. Hidden with reduced transparency.
function Ambient({ src }) {
  return <div className="ambient" aria-hidden="true">{src && <img key={src} src={src} alt="" />}</div>;
}

function Connecting({ online }) {
  return <div className="center-screen">
    <span className="brand-mark large"><Mark width={50} height={30} animate /></span>
    {online ? <><div className="loader" aria-hidden="true" /><p>Connecting to the Mac …</p></>
      : <><h1>Mac not reachable</h1><p>Check that Helix is open on the Mac and the remote is turned on. This page reconnects automatically.</p></>}
  </div>;
}

// ---------- Now playing ----------

function NowPlaying({ state, command, ready, receivedAt, onQueue, onClose, nav }) {
  const [seek, setSeek] = useState(null), [volume, setVolume] = useState(null), [, tick] = useState(0);
  // Interpolate between polls so the progress bar moves smoothly.
  useEffect(() => { if (!state?.playing) return; const id = setInterval(() => tick(t => t + 1), 500); return () => clearInterval(id); }, [state?.playing]);
  const current = state?.current;
  const duration = state?.duration || 0;
  const live = state?.playing ? Math.min(duration, (state.position || 0) + (performance.now() - receivedAt) / 1000) : (state?.position || 0);
  const position = seek ?? live;
  const airPlay = state?.source === 'airPlay';
  const linkable = !airPlay && ready && current?.catalogID;
  const canControl = ready || state?.canControl;
  const canToggle = canControl && (current || state?.queue?.length);
  const mismatch = state?.outputRate > 0 && state.rate > 0 && Math.round(state.outputRate) !== state.rate;

  return <section className="now" aria-label="Now Playing">
    {onClose && <button type="button" className="now-close" onClick={onClose} aria-label="Close player"><CaretDown weight="bold" /></button>}
    <div className={`now-cover ${state?.playing ? 'playing' : ''}`}><Cover src={current?.artwork} size="xl" alt={current ? `Artwork of ${current.title}` : ''} /></div>
    <div className="now-meta">
      <div className="min-w-0">
        {linkable ? <h1><button type="button" className="link-text" onClick={() => nav.album(current.catalogID)}>{current.title}</button></h1>
          : <h1>{current?.title || 'Nothing selected'}</h1>}
        {linkable && current.artist ? <p><button type="button" className="link-text" onClick={() => nav.artist(current.catalogID)}>{current.artist}</button></p>
          : <p>{current ? (current.artist || (airPlay ? 'AirPlay' : 'Apple Music')) : 'Choose a song in your library.'}</p>}
      </div>
      {state?.loading && <span className="pill">Loading</span>}
    </div>
    {airPlay && <p className="quality"><Mark width={18} height={11} />{state.quality}</p>}
    {!airPlay && state?.rate > 0 && <p className={`quality ${mismatch ? 'warn' : ''}`} title={mismatch ? `The Mac outputs at ${kHz(state.outputRate)}.` : 'No resampling'}>
      <Mark width={18} height={11} />{state.rate > 48000 ? 'Hi-Res Lossless' : 'Lossless'}<span>{state.depth}-bit, {kHz(state.rate)}</span>
    </p>}
    <div className={`timeline ${state?.loading ? 'buffering' : ''}`}>
      <Range label="Wiedergabeposition" value={position} max={Math.max(1, duration)} disabled={!ready || !duration || !state?.canSeek}
        onChange={setSeek} onCommit={v => { setSeek(null); command('seek', { position: Math.min(v, duration) }); }} />
      <div className="times"><span>{time(position)}</span><span>-{time(Math.max(0, duration - position))}</span></div>
    </div>
    <div className="transport">
      <IconButton label="Previous song" onClick={() => command('previous')} disabled={!ready || !current || airPlay}><SkipBack weight="fill" /></IconButton>
      <button type="button" className="play" aria-label={airPlay ? 'Disconnect AirPlay' : state?.playing ? 'Pause' : 'Play'} onClick={() => command('toggle')} disabled={!canToggle}>
        {airPlay ? <Stop weight="fill" /> : state?.playing ? <Pause weight="fill" /> : <Play weight="fill" />}
      </button>
      <IconButton label="Next song" onClick={() => command('next')} disabled={!ready || !state?.queue?.length || airPlay}><SkipForward weight="fill" /></IconButton>
    </div>
    <div className="volume">
      <SpeakerLow aria-hidden="true" />
      <Range label="Volume" value={volume ?? state?.volume ?? 1} max={1} disabled={!canControl} className="range-quiet"
        onChange={setVolume} onCommit={v => { setVolume(null); command('volume', { volume: v }); }} />
      <SpeakerHigh aria-hidden="true" />
    </div>
    {state?.queue?.length > 0 && <button type="button" className="up-next lg-hidden" onClick={onQueue}>
      <span>Playing Next</span><strong>{state.queue[0].title}</strong><ArrowRight />
    </button>}
  </section>;
}

function MiniPlayer({ state, command, ready, onOpen }) {
  const airPlay = state?.source === 'airPlay';
  const progress = state.duration ? Math.min(100, (state.position / state.duration) * 100) : 0;
  return <div className="mini">
    <button type="button" className="mini-open" onClick={onOpen} aria-label="Open player">
      <Cover src={state.current.artwork} /><span className="min-w-0"><strong>{state.current.title}</strong><small>{state.current.artist}</small></span>
    </button>
    <IconButton label={airPlay ? 'Disconnect AirPlay' : state.playing ? 'Pause' : 'Play'} onClick={() => command('toggle')} disabled={!ready && !state.canControl}>{airPlay ? <Stop weight="fill" /> : state.playing ? <Pause weight="fill" /> : <Play weight="fill" />}</IconButton>
    <IconButton label="Next song" onClick={() => command('next')} disabled={!ready || !state.queue?.length || airPlay}><SkipForward weight="fill" /></IconButton>
    <span className="mini-progress" style={{ '--fill': `${progress}%` }} aria-hidden="true" />
  </div>;
}

// ---------- Queue ----------

function QueuePane({ state, command, ready, onBrowse, nav }) {
  const [selected, setSelected] = useState(null);
  const queue = state?.queue || [];
  const index = selected ? queue.findIndex(item => item.id === selected.id) : -1;
  const act = async (action, fields, message) => { setSelected(null); await command(action, fields, message); };
  return <div className="queue">
    <div className="pane-heading"><h2>Playing Next</h2>
      {queue.length > 0 && <button type="button" className="text-button" onClick={() => command('clear', {}, 'Queue cleared')} disabled={!ready}>Clear</button>}</div>
    {!queue.length ? <div className="empty">
      <Queue weight="light" /><h3>Nothing in the Queue</h3>
      <p>In your library, tap the three dots next to a song and choose “Play Next” or “Play Last”.</p>
      <button type="button" className="button secondary" onClick={onBrowse}>Go to Library<ArrowRight /></button>
    </div> : <ol className="list">
      {queue.map((item, i) => <li key={item.id} className="row">
        <button type="button" className="row-main" onClick={() => command('playQueued', { id: item.id })} disabled={!ready} aria-label={`Play ${item.title} now`}>
          <Cover src={item.artwork} /><span className="row-text"><strong>{item.title}</strong><small>{item.artist || 'Apple Music'}</small></span>
        </button>
        <IconButton label={`Actions for ${item.title}`} onClick={() => setSelected(item)} disabled={!ready}><DotsThree weight="bold" /></IconButton>
      </li>)}
    </ol>}
    <Sheet open={!!selected} onClose={() => setSelected(null)} title="Titelaktionen">
      {selected && <>
        <SheetHeader item={selected} subtitle={index >= 0 ? `Position ${index + 1} of ${queue.length}` : selected.artist} />
        <SheetAction icon={<Play weight="fill" />} onClick={() => act('playQueued', { id: selected.id })}>Play Now</SheetAction>
        <SheetAction icon={<ArrowLineUp />} disabled={index <= 0} onClick={() => act('move', { id: selected.id, index: 0, revision: state.revision })}>Move to Top</SheetAction>
        <SheetAction icon={<ArrowUp />} disabled={index <= 0} onClick={() => act('move', { id: selected.id, index: index - 1, revision: state.revision })}>Move Up</SheetAction>
        <SheetAction icon={<ArrowDown />} disabled={index < 0 || index >= queue.length - 1} onClick={() => act('move', { id: selected.id, index: index + 1, revision: state.revision })}>Move Down</SheetAction>
        <SheetAction icon={<VinylRecord />} onClick={() => { setSelected(null); nav.album(selected.catalogID); }}>Go to Album</SheetAction>
        <SheetAction icon={<MicrophoneStage />} onClick={() => { setSelected(null); nav.artist(selected.catalogID); }}>Go to Artist</SheetAction>
        <SheetAction icon={<Trash />} destructive onClick={() => act('remove', { id: selected.id }, 'Removed')}>Remove from Queue</SheetAction>
        <button type="button" className="sheet-cancel" onClick={() => setSelected(null)}>Cancel</button>
      </>}
    </Sheet>
  </div>;
}

// ---------- Library ----------

const CATEGORIES = [['songs', 'Songs'], ['albums', 'Albums'], ['playlists', 'Playlists']];

function useLibrary(path, ready) {
  const [items, setItems] = useState([]), [next, setNext] = useState(null), [loading, setLoading] = useState(false), [error, setError] = useState('');
  const generation = useRef(0);
  const load = useCallback(async (address, append) => {
    const current = ++generation.current; setLoading(true); setError('');
    try {
      const page = await request(`/api/library?path=${encodeURIComponent(address)}`);
      if (generation.current !== current) return;
      setItems(previous => append ? [...previous, ...page.items] : page.items); setNext(page.next);
    } catch (e) { if (generation.current === current) setError(e.message); }
    finally { if (generation.current === current) setLoading(false); }
  }, []);
  useEffect(() => { setItems([]); setNext(null); if (ready && path) load(path, false); return () => { generation.current++; }; }, [path, ready, load]);
  return { items, next, loading, error, more: () => next && !loading && load(next, true), retry: () => load(path, false) };
}

function Library({ state, command, ready, notify, nav }) {
  const [category, setCategory] = useState('songs'), [query, setQuery] = useState('');
  useEffect(() => { setQuery(''); window.scrollTo({ top: 0 }); }, [category]);
  return <div className="library">
    <div className="segmented small" role="tablist" aria-label="Library section">
      {CATEGORIES.map(([value, title]) => <button key={value} role="tab" aria-selected={category === value} onClick={() => setCategory(value)}>{title}</button>)}
    </div>
    <SearchField value={query} onChange={setQuery} placeholder={`Search ${CATEGORIES.find(c => c[0] === category)[1]}`} />
    <CategoryList key={category} category={category} query={query} state={state} command={command} ready={ready} notify={notify} nav={nav} onOpen={nav.openCollection} />
  </div>;
}

function SearchField({ value, onChange, placeholder, autoFocus }) {
  return <div className="search"><MagnifyingGlass aria-hidden="true" />
    <input type="search" value={value} onChange={e => onChange(e.target.value)} placeholder={placeholder} aria-label={placeholder} enterKeyHint="search" autoFocus={autoFocus} />
    {value && <IconButton label="Clear search" className="search-clear" onClick={() => onChange('')}><X /></IconButton>}
  </div>;
}

const matches = (item, query) => !query || `${item.title} ${item.artist} ${item.album || ''}`.toLocaleLowerCase('de').includes(query.trim().toLocaleLowerCase('de'));

/// Loads the next page when the end of the list scrolls into view.
function LoadMore({ library }) {
  const ref = useRef(null);
  useEffect(() => {
    if (!library.next || !ref.current) return;
    const observer = new IntersectionObserver(entries => { if (entries[0].isIntersecting) library.more(); }, { rootMargin: '600px' });
    observer.observe(ref.current); return () => observer.disconnect();
  }, [library]);
  if (!library.next && !library.loading) return null;
  return <div ref={ref} className="load-more">{library.loading ? <span className="loader small" aria-label="Loading" /> :
    <button type="button" className="button secondary" onClick={library.more}>Load more<CaretDown /></button>}</div>;
}

function LibraryStatus({ library, query, empty }) {
  if (library.error) return <div className="inline-error" role="alert"><p>{library.error}</p><button type="button" className="button secondary" onClick={library.retry}>Reload</button></div>;
  if (library.loading && !library.items.length) return <div className="skeletons" aria-label="Loading library">{Array.from({ length: 8 }, (_, i) => <div key={i} className="skeleton-row"><span /><span /></div>)}</div>;
  if (!library.items.length || empty) return <div className="empty compact"><MusicNotes weight="light" /><h3>{query ? 'No Results' : 'Nothing Here Yet'}</h3>
    <p>{query ? (library.next ? 'Searched the items loaded so far. Scroll on to load more.' : 'Try a different search term.') : 'Your Apple Music library appears here.'}</p></div>;
  return null;
}

function CategoryList({ category, query, state, command, ready, notify, nav, onOpen }) {
  const library = useLibrary(`/v1/me/library/${category}`, ready);
  const [selected, setSelected] = useState(null);
  const filtered = library.items.filter(item => matches(item, query));
  return <>
    <LibraryStatus library={library} query={query} empty={!filtered.length} />
    {category === 'songs' ? <ol className="list">
      {filtered.map((item, i) => <TrackRow key={`${item.id}-${i}`} item={item} current={state?.current?.catalogID === item.catalogID} ready={ready}
        onPlay={() => command('playItem', itemPayload(item))} onMore={() => setSelected(item)} />)}
    </ol> : <div className="grid">
      {filtered.map(item => <button type="button" key={item.id} className="tile" disabled={!item.trackPath} onClick={() => onOpen(item)}>
        <Cover src={item.artworkLarge || item.artwork} size="tile" /><strong>{item.title}</strong>
        <small>{item.artist || (item.trackCount ? `${item.trackCount} songs` : 'Playlist')}</small>
      </button>)}
    </div>}
    <LoadMore library={library} />
    <TrackSheet item={selected} onClose={() => setSelected(null)} command={command} notify={notify} nav={nav} />
  </>;
}

/** The app's mark (see helix.js); while `animate`, the helix turns. */
function Mark({ width, height, animate = false }) {
  const ref = useRef(null);
  useEffect(() => {
    const draw = phase => { ref.current.innerHTML = markSVG(width, height, phase); };
    if (!animate || matchMedia('(prefers-reduced-motion: reduce)').matches) { draw(0); return; }
    let frame = requestAnimationFrame(function loop(ms) { draw(ms / 1000 * 2.4); frame = requestAnimationFrame(loop); });
    return () => cancelAnimationFrame(frame);
  }, [width, height, animate]);
  return <span ref={ref} className="mark" aria-hidden="true" />;
}

function TrackRow({ item, current, playing, ready, onPlay, onMore, number }) {
  return <li className={`row ${current ? 'current' : ''} ${item.playable ? '' : 'unavailable'}`}>
    <button type="button" className="row-main" onClick={onPlay} disabled={!ready || !item.playable}
      aria-label={item.playable ? `Play ${item.title}` : `${item.title}, not available`}>
      {number != null ? <span className="row-number">{current ? <Mark width={20} height={12} animate={playing} /> : number}</span> : <Cover src={item.artwork} />}
      <span className="row-text"><strong>{item.title}</strong><small>{item.playable ? (item.artist || 'Apple Music') : 'Not available'}</small></span>
      {item.duration > 0 && <span className="row-time">{time(item.duration)}</span>}
    </button>
    {item.playable && <IconButton label={`Actions for ${item.title}`} onClick={onMore} disabled={!ready}><DotsThree weight="bold" /></IconButton>}
  </li>;
}

function TrackSheet({ item, onClose, command, notify, nav, inAlbum }) {
  const run = async (action, fields, message) => { onClose(); await command(action, fields, message); };
  return <Sheet open={!!item} onClose={onClose} title="Titelaktionen">
    {item && <>
      <SheetHeader item={item} />
      <SheetAction icon={<Play weight="fill" />} onClick={() => run('playItem', itemPayload(item))}>Play</SheetAction>
      <SheetAction icon={<ListPlus />} onClick={() => run('enqueueItem', { ...itemPayload(item), first: true }, 'Playing next')}>Play Next</SheetAction>
      <SheetAction icon={<Plus />} onClick={() => run('enqueueItem', itemPayload(item), 'Added to the end')}>Play Last</SheetAction>
      {item.catalogID && !inAlbum && <SheetAction icon={<VinylRecord />} onClick={() => { onClose(); nav.album(item.catalogID); }}>Go to Album</SheetAction>}
      {item.catalogID && <SheetAction icon={<MicrophoneStage />} onClick={() => { onClose(); nav.artist(item.catalogID); }}>Go to Artist</SheetAction>}
      <button type="button" className="sheet-cancel" onClick={onClose}>Cancel</button>
    </>}
  </Sheet>;
}

function CollectionView({ collection, onBack, state, command, ready, notify, nav }) {
  const library = useLibrary(collection.trackPath, ready);
  const [selected, setSelected] = useState(null), [query, setQuery] = useState(''), [fullAlbum, setFullAlbum] = useState(null);
  // Library albums can hold only some titles; offer the whole album from Apple Music.
  useEffect(() => {
    if (!ready || collection.type !== 'library-albums') return;
    let active = true;
    request(`/api/catalog-album?id=${encodeURIComponent(collection.id)}`).then(r => { if (active) setFullAlbum(r.album); }).catch(() => {});
    return () => { active = false; };
  }, [collection.id, collection.type, ready]);
  const showFull = fullAlbum && !library.loading && (fullAlbum.trackCount || 0) > library.items.length;
  const playable = library.items.filter(item => item.playable);
  const filtered = library.items.map((item, i) => ({ item, i })).filter(({ item }) => matches(item, query));
  const isAlbum = collection.type === 'library-albums' || collection.type === 'albums';
  const playFrom = index => command('playItems', { items: library.items.slice(index).filter(i => i.playable).slice(0, 1000).map(itemPayload) });
  const total = library.items.reduce((sum, item) => sum + (item.duration || 0), 0);
  return <div className="collection">
    <button type="button" className="back" onClick={onBack}><ArrowLeft />Back</button>
    <div className="collection-head">
      <Cover src={collection.artworkLarge || collection.artwork} size="tile" />
      <div className="min-w-0">
        <span className="kind">{isAlbum ? 'Album' : 'Playlist'}</span>
        <h2>{collection.title}</h2>
        {collection.artist && (isAlbum ? <p className="accent"><button type="button" className="link-text" onClick={() => nav.albumArtist(collection)}>{collection.artist}</button></p>
          : <p className="accent">{collection.artist}</p>)}
        <p className="muted">{showFull ? `${library.items.length} of ${fullAlbum.trackCount} songs in your library` : `${library.items.length}${library.next ? '+' : ''} songs`}{total > 60 ? `, ${Math.round(total / 60)} min` : ''}</p>
      </div>
    </div>
    <div className="collection-actions">
      <button type="button" className="button primary" disabled={!ready || !playable.length} onClick={() => playFrom(0)}><Play weight="fill" />Play</button>
      <button type="button" className="button secondary" disabled={!ready || !playable.length} onClick={() => command('playItems', { items: playable.slice(0, 1000).map(itemPayload), shuffle: true })}><Shuffle />Shuffle</button>
      <IconButton label="Play all last" disabled={!ready || !playable.length} onClick={() => command('enqueueItems', { items: playable.slice(0, 1000).map(itemPayload) }, `${playable.length} songs added`)}><ListPlus /></IconButton>
    </div>
    {showFull && <button type="button" className="button secondary wide full-album" onClick={() => nav.openCollection(fullAlbum)}><Stack />Show Full Album ({fullAlbum.trackCount} songs)</button>}
    {library.items.length > 12 && <SearchField value={query} onChange={setQuery} placeholder="Search this list" />}
    <LibraryStatus library={library} query={query} empty={!filtered.length} />
    <ol className="list">
      {filtered.map(({ item, i }) => <TrackRow key={`${item.id}-${i}`} item={item} number={isAlbum ? i + 1 : undefined} current={state?.current?.catalogID === item.catalogID} playing={state?.playing}
        ready={ready} onPlay={() => playFrom(i)} onMore={() => setSelected(item)} />)}
    </ol>
    <LoadMore library={library} />
    <TrackSheet item={selected} onClose={() => setSelected(null)} command={command} notify={notify} nav={nav} inAlbum={isAlbum} />
  </div>;
}

// ---------- Search and artists ----------

/// Apple Music catalog search with a short debounce.
function SearchPane({ term, onTerm, state, command, ready, notify, nav }) {
  const [result, setResult] = useState({ term: '', sections: [] }), [loading, setLoading] = useState(false), [error, setError] = useState('');
  useEffect(() => {
    const text = term.trim();
    if (!text || !ready) { setResult({ term: '', sections: [] }); setLoading(false); return; }
    let active = true; setLoading(true); setError('');
    const timer = setTimeout(async () => {
      try { const r = await request(`/api/search?term=${encodeURIComponent(text)}`); if (active) setResult({ term: text, sections: r.sections || [] }); }
      catch (e) { if (active) setError(e.message); }
      finally { if (active) setLoading(false); }
    }, 300);
    return () => { active = false; clearTimeout(timer); };
  }, [term, ready]);
  return <div className="search-pane">
    <div className="pane-heading"><h2>Search</h2></div>
    <SearchField value={term} onChange={onTerm} placeholder="Songs, albums, artists" autoFocus={!term} />
    {error && <div className="inline-error" role="alert"><p>{error}</p></div>}
    {!term.trim() ? <CategoryGrid ready={ready} nav={nav} />
      : loading && !result.sections.length ? <div className="skeletons" aria-label="Searching">{Array.from({ length: 6 }, (_, i) => <div key={i} className="skeleton-row"><span /><span /></div>)}</div>
      : !loading && !result.sections.length && !error ? <div className="empty compact"><MusicNotes weight="light" /><h3>No Results</h3><p>Try a different search term.</p></div>
      : <Sections sections={result.sections} state={state} command={command} ready={ready} notify={notify} nav={nav} />}
  </div>;
}

/// Rows for search results and artist pages: artists, songs and covers.
function Sections({ sections, state, command, ready, notify, nav }) {
  const [selected, setSelected] = useState(null);
  return <>
    {sections.map(section => <section key={section.id} className="browse-section" aria-label={section.title}>
      <h3>{section.title}</h3>
      {section.style === 'artists' ? <div className="artist-row">
        {section.items.map(item => <button type="button" key={item.id} className="artist-chip" onClick={() => nav.openArtist(item.id, item.title)}>
          <span className="cover cover-artist">{item.artwork ? <img src={item.artworkLarge || item.artwork} alt="" loading="lazy" decoding="async" /> : <UserCircle weight="light" />}</span>
          <strong>{item.title}</strong>
        </button>)}
      </div> : section.style === 'songs' ? <ol className="list">
        {section.items.slice(0, 10).map((item, i) => <TrackRow key={`${item.id}-${i}`} item={item} current={state?.current?.catalogID === item.catalogID} ready={ready}
          onPlay={() => command('playItem', itemPayload(item))} onMore={() => setSelected(item)} />)}
      </ol> : <div className="grid">
        {section.items.map(item => <button type="button" key={item.id} className="tile" disabled={!item.trackPath} onClick={() => nav.openCollection(item)}>
          <Cover src={item.artworkLarge || item.artwork} size="tile" /><strong>{item.title}</strong>
          <small>{item.artist || (item.trackCount ? `${item.trackCount} songs` : 'Playlist')}</small>
        </button>)}
      </div>}
    </section>)}
    <TrackSheet item={selected} onClose={() => setSelected(null)} command={command} notify={notify} nav={nav} />
  </>;
}

function ArtistPane({ route, onBack, state, command, ready, notify, nav }) {
  const [page, setPage] = useState(null), [error, setError] = useState(''), [bioOpen, setBioOpen] = useState(false);
  useEffect(() => {
    if (!ready) return;
    let active = true; setPage(null); setError('');
    request(`/api/artist?id=${encodeURIComponent(route.id)}`).then(p => { if (active) setPage(p); }).catch(e => { if (active) setError(e.message); });
    return () => { active = false; };
  }, [route.id, ready]);
  const top = page?.sections?.find(s => s.id === 'top-songs')?.items?.filter(i => i.playable) || [];
  const name = page?.name || route.name;
  return <div className="artist-pane">
    <button type="button" className="back" onClick={onBack}><ArrowLeft />Back</button>
    <div className={`artist-head ${page?.banner ? 'with-banner' : ''}`}>
      {page?.banner ? <img className="artist-banner" src={page.banner} alt="" /> : <span className="cover cover-artist large">{page?.artwork ? <img src={page.artwork} alt="" /> : <UserCircle weight="light" />}</span>}
      <h2>{name}</h2>
    </div>
    <div className="collection-actions two">
      <button type="button" className="button primary" disabled={!ready || !top.length} onClick={() => command('playItems', { items: top.map(itemPayload) })}><Play weight="fill" />Play</button>
      <button type="button" className="button secondary" disabled={!ready || !top.length} onClick={() => command('playItems', { items: top.map(itemPayload), shuffle: true })}><Shuffle />Shuffle</button>
    </div>
    {error && <div className="inline-error" role="alert"><p>{error}</p></div>}
    {!page && !error ? <div className="skeletons" aria-label="Loading artist">{Array.from({ length: 6 }, (_, i) => <div key={i} className="skeleton-row"><span /><span /></div>)}</div>
      : page && <Sections sections={page.sections || []} state={state} command={command} ready={ready} notify={notify} nav={nav} />}
    {page?.bio && <section className="browse-section bio">
      <h3>About {name}</h3>
      <p className={bioOpen ? '' : 'clamped'}>{page.bio}</p>
      <button type="button" className="text-button" onClick={() => setBioOpen(o => !o)}>{bioOpen ? 'Less' : 'More'}</button>
    </section>}
  </div>;
}

// ---------- Editorial pages ----------

function useJSON(path, ready) {
  const [data, setData] = useState(null), [error, setError] = useState(''), [attempt, setAttempt] = useState(0);
  useEffect(() => {
    if (!ready || !path) return;
    let active = true; setError('');
    request(path).then(d => { if (active) setData(d); }).catch(e => { if (active) setError(e.message); });
    return () => { active = false; };
  }, [path, ready, attempt]);
  return { data, error, retry: () => setAttempt(a => a + 1) };
}

/// Home, New and category pages: horizontal shelves like in the Music app.
function EditorialPane({ title, path, onBack, state, command, ready, notify, nav }) {
  const { data, error, retry } = useJSON(path, ready);
  return <div className="editorial">
    {onBack && <button type="button" className="back" onClick={onBack}><ArrowLeft />Back</button>}
    <div className="pane-heading"><h2 className="page-title">{title}</h2></div>
    {error && <div className="inline-error" role="alert"><p>{error}</p><button type="button" className="button secondary" onClick={retry}>Reload</button></div>}
    {!data && !error ? <div className="skeletons" aria-label="Loading">{Array.from({ length: 6 }, (_, i) => <div key={i} className="skeleton-row"><span /><span /></div>)}</div>
      : data && !data.sections?.length ? <div className="empty compact"><MusicNotes weight="light" /><h3>Nothing to Play</h3><p>This page has nothing that can be played here right now.</p></div>
      : data && <Shelves sections={data.sections} state={state} command={command} ready={ready} notify={notify} nav={nav} />}
  </div>;
}

function Shelves({ sections, state, command, ready, notify, nav }) {
  const [selected, setSelected] = useState(null);
  return <>
    {sections.map(section => <section key={section.id} className="browse-section" aria-label={section.title || 'Highlights'}>
      {section.title && <h3>{section.title}</h3>}
      {section.style === 'hero' ? <div className="shelf">
        {section.items.map(item => <button type="button" key={item.id} className="wide-card" onClick={() => nav.openCollection(item)}>
          {item.badge && <span className="badge-text">{item.badge}</span>}
          <strong>{item.title}</strong><small>{item.artist}</small>
          <span className="wide-art">
            {item.wideArtwork || item.artworkLarge ? <img src={item.wideArtwork || item.artworkLarge} alt="" loading="lazy" decoding="async" /> : null}
            {item.summary && <em>{item.summary}</em>}
          </span>
        </button>)}
      </div> : section.style === 'featured' ? <div className="shelf">
        {section.items.map(item => <button type="button" key={item.id} className="feature-card" onClick={() => nav.openCollection(item)}>
          <Cover src={item.artworkLarge || item.artwork} size="tile" />
          <span className="feature-text" style={{ '--card': item.color ? `#${item.color}` : 'var(--accent)' }}><strong>{item.title}</strong><small>{item.summary || item.artist}</small></span>
        </button>)}
      </div> : section.style === 'covers' ? <div className="shelf">
        {section.items.map(item => <button type="button" key={item.id} className="tile shelf-tile" disabled={!item.trackPath} onClick={() => nav.openCollection(item)}>
          <Cover src={item.artworkLarge || item.artwork} size="tile" /><strong>{item.title}</strong>
          <small>{item.artist || (item.trackCount ? `${item.trackCount} songs` : 'Playlist')}</small>
        </button>)}
      </div> : section.style === 'artists' ? <div className="artist-row">
        {section.items.map(item => <button type="button" key={item.id} className="artist-chip" onClick={() => nav.openArtist(item.id, item.title)}>
          <span className="cover cover-artist">{item.artwork ? <img src={item.artworkLarge || item.artwork} alt="" loading="lazy" decoding="async" /> : <UserCircle weight="light" />}</span>
          <strong>{item.title}</strong>
        </button>)}
      </div> : <ol className="list">
        {section.items.slice(0, 8).map((item, i) => <TrackRow key={`${item.id}-${i}`} item={item} current={state?.current?.catalogID === item.catalogID} ready={ready}
          onPlay={() => command('playItem', itemPayload(item))} onMore={() => setSelected(item)} />)}
      </ol>}
    </section>)}
    <TrackSheet item={selected} onClose={() => setSelected(null)} command={command} notify={notify} nav={nav} />
  </>;
}

/// Apple Music's search categories (genres, moods, charts).
function CategoryGrid({ ready, nav }) {
  const { data, error, retry } = useJSON('/api/categories', ready);
  return <section className="browse-section" aria-label="Browse Categories">
    <h3>Browse Categories</h3>
    {error && <div className="inline-error" role="alert"><p>{error}</p><button type="button" className="button secondary" onClick={retry}>Reload</button></div>}
    {!data && !error ? <div className="category-grid">{Array.from({ length: 6 }, (_, i) => <span key={i} className="category-tile skeleton" />)}</div>
      : data && <div className="category-grid">
        {data.categories.map(category => <button type="button" key={`${category.kind}-${category.id}`} className="category-tile"
          style={{ '--tile': category.color ? `#${category.color}` : 'var(--surface-2)' }}
          onClick={() => nav.openCategory({ id: category.id, kind: category.kind, title: category.title })}>
          {category.artwork && <img src={category.artwork} alt="" loading="lazy" decoding="async" />}
          <strong>{category.title}</strong>
        </button>)}
      </div>}
  </section>;
}

// ---------- Link ----------

function LinkSheet({ open, onClose, command }) {
  const [url, setURL] = useState('');
  const valid = /^https:\/\/music\.apple\.com\//i.test(url.trim());
  const run = async (action, fields, message) => { if (await command(action, { url: url.trim(), ...fields }, message)) { setURL(''); onClose(); } };
  return <Sheet open={open} onClose={onClose} title="Paste Song Link">
    <form className="link-form" onSubmit={e => { e.preventDefault(); if (valid) run('playURL', {}, 'Playback started'); }}>
      <h2>Paste Song Link</h2>
      <p>In Apple Music, choose “Share” and then “Copy Link” on a song.</p>
      <label htmlFor="track-url">Apple Music link</label>
      <input id="track-url" type="url" inputMode="url" value={url} onChange={e => setURL(e.target.value)} placeholder="https://music.apple.com/…" autoComplete="off" />
      <button className="button primary wide" disabled={!valid}><Play weight="fill" />Play Now</button>
      <div className="link-secondary">
        <button type="button" className="button secondary" disabled={!valid} onClick={() => run('enqueueURL', { first: true }, 'Playing next')}>Play Next</button>
        <button type="button" className="button secondary" disabled={!valid} onClick={() => run('enqueueURL', {}, 'Added to the end')}>Play Last</button>
      </div>
      <button type="button" className="sheet-cancel" onClick={onClose}>Cancel</button>
    </form>
  </Sheet>;
}

createRoot(document.getElementById('root')).render(<App />);
