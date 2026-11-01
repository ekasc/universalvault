# UniversalVault swarm

Run: 2026-10-31T01-01-48-274Z
Model: deepseek-v4.1-flash
Rounds: 1
Observations: 14

## couple-01 / first-run

**Ravi Menon (normal)**

Okay, first ten minutes, honestly:

Expected: a place to keep my address, phone, PAN-ish stuff and card number so I stop retyping them into every form. Saw "menu bar" and "no cloud sync" and thought fine, less to set up.

Looked for: the shortcut. That's it. Did not open Settings, did not read anything. Control+Option+V, searched "address", pressed Return, it typed into the form I had open. That is exactly the thing I wanted and it took about forty seconds, so I was already happy.

Then I hit an item that was "protected", and it wanted Touch ID before it would show me the field. For my own home address. On my own Mac. So I closed the palette and typed it by hand, because that was faster than agreeing to something I did not want to think about.

Where I stopped: there. I never got to "agents" or the JSON thing, no idea what that is, and I will not be reading the docs. When I see a lock I assume the app is being difficult, not that it is protecting me.

What it should have told me at each step: on first launch, one line saying what is already unlocked and what will ask for a fingerprint, in plain words. On the protected item, say "this one asks for Touch ID" BEFORE I press Return, not after. And tell me plainly that ordinary details are not behind the fingerprint, so the only reason I ever see a prompt is that I chose to protect that item.

Also: it opens at launch with no prompt, so I assumed everything was available. If some items are not, that has to be visible in the list, not discovered by getting stopped mid-form.

**Sam Okafor (critical)**

Ten minutes in, here is the honest audit trail.

Before I opened it, I expected: a prompt before anything is decrypted. What I got: the vault opens at launch with no prompt at all. That single sentence reframes the whole product. Anything not marked "protected" is decrypted and readable by every process running as me — from t=0. The security boundary here is not the vault, it's my user session. That is a defensible design choice. It is not what the copy implies.

What I actually tried:

1. Slept the machine with an unprotected item on screen. It came back readable. So protected items closing on sleep/lock/timeout protects exactly one thing: whoever walks up to my unlocked laptop. It does nothing about local processes, and I assumed it did until I read the third sentence twice.

2. Control+Option+V into a terminal. Values arrive as synthetic keystrokes, meaning anything with a keyboard event tap — a keylogger, an accessibility tool, a "helpful" utility — sees exactly what I just retrieved, in cleartext, at the moment of maximum convenience. The palette is the extraction path as well as the guard.

3. Marked an item "for agents" and printed the JSON. Then I put something in that item I would personally call sensitive and printed it again. It came out. Of course it did — the app cannot evaluate my judgement. So "non-sensitive" is a label I promise to keep, not a control the app enforces. The feature is honest if it's described as "this item is readable by any local process."

What it should have told me, at each step:

At launch: "This vault is unlocked. Anyone or anything running as you can read everything not marked protected."
At the agent labelling step: "Fields marked for agents are exportable by any local command with your privileges. The non-sensitive promise is yours to keep."
At the palette: "Values are typed via synthetic keystrokes and will be visible to anything that can observe keyboard input."

Where I stopped: before entering a single real credential. "Asks for Touch ID before they are read" is a good line, and I cannot verify from outside what "read" covers — the palette, the agent export path, or the copy of the value sitting in memory after it's been typed. Good questions to answer in public: is the protected key held in the Secure Enclave, or in memory after first Touch ID? Does locking protected items actually zero the plaintext or just hide it in the UI? Does the agent command respect the protected flag?

No cloud sync is the strongest claim on the page, and it's the only one I believed without testing. Everything reassuring needs a footnote; the architecture is fine, the framing isn't.

## couple-01 / daily-fill

**Ravi Menon (normal)**

This is exactly the kind of thing I want. Control+Option+V over whatever app I'm in, type an address or card number with Return — that's the whole point for me, filling forms without retyping. Two things I'd worry about: I basically never open settings or read the setup screens, so I'd just assume it's ready because it opens at launch. And if ordinary details like my address start asking for Touch ID, I'll get annoyed and stop using it. Keep the fingerprint only for the genuinely sensitive stuff and I'm in.

## couple-01 / trust

**Ravi Menon (normal)**

This is exactly what I've been looking for. Control+Option+V and paste the field straight into any form — no retyping my address every time. And it doesn't ask for a fingerprint for the ordinary stuff, which is the part that usually makes me give up on these apps. It opens at launch with no prompt, so it's just there when I need it. Keeping my address and card details in it from day one.

**Sam Okafor (critical)**

Reading this as a threat model, not a feature list. Three things I'd need to resolve before this goes anywhere near my passport scan or card details.

1) "The vault opens at launch without a prompt." That's the whole ballgame. Anything decrypted at launch is readable by anything running as me — every menu-bar utility, every npm postinstall, every script I've half-forgotten about. It also means the *index* is almost certainly in memory, which means your "search a field" palette is a plaintext oracle for anyone who can drive a keystroke. If the search index were built on demand from encrypted records under Touch ID, that's a very different product. Ask them which it is. The answer is probably "the fast one."

2) "Protected" is doing a lot of work here. Two thresholds on the same item — sealed under a second key, and separately "marked for agents" to print non-sensitive fields as JSON — means the app has an internal notion of which fields are non-sensitive, and that notion is fixed by the developer, not by me. I want per-field control, and I want the agent export to fail closed (refuse to emit anything) rather than trust a label someone else set. "Non-sensitive" is a claim about my data made by a stranger.

3) The lock model is asymmetric in the wrong direction: sleep/lock/timeout seal *protected items only*, while Vault > Lock closes everything. So the default state after I shut the lid is "vault open, unsealed items readable." That's a decision someone made — presumably to keep the menu-bar convenience feeling instant. It means the unsealed tier is the tier that's actually always available, and I'd be putting things there out of laziness within a week.

What would make me stop: cloud sync appearing in a point release, an "export all" that doesn't re-prompt, or a second key stored somewhere recoverable "for my convenience." What would move me forward: a written threat model, the key derivation and where the second key lives, a statement of what an unprivileged process running as me can read at launch, and a build I can reproduce. The clipboard/focused-field injection path deserves its own paragraph too — typing values into whatever's focused is a keylogger's best friend, and it's the one place a "safe" design leaks into an unsafe one.

No cloud sync is genuinely good. It's also the cheapest promise to keep. Evidence beats reassurance — until then, it's a nice menu-bar app, not a vault.

## couple-01 / removal

**Ravi Menon (normal)**

Speaking as someone who just wants his address and card handy without retyping: the Control+Option+V palette is the entire product for me — keep that above all else.

Three I'd remove:
1. The Touch ID gate on protected items. I'd hit the button, get the prompt, get annoyed, and go back to retyping by hand. Losing it means protected fields are only as safe as the Mac login — fine by me, honestly.
2. The "agents" JSON output. I don't know what a local command is and I'm never going to use it, but I'd still worry it's leaking something. Removing it loses nothing for people like me.
3. The extra confirmations on locking (and the "lock only protected items" distinction). I close windows instead of reading them, so a dialog I don't read is just a speed bump that trains me to click through everything — which is worse than no dialog.

Keep: opening at launch with no prompt and no setup. If an app makes me configure something first, I assume it's already fine and skip it anyway.

**Sam Okafor (critical)**

Three I'd cut, and what breaks:

1. **The "marked for agents" toggle.** Removing it breaks local automation, and that's the point. "Non-sensitive fields" is self-certified by whoever created the item, at the moment they were least thinking about it. Your own threat model note gives the answer: anything decrypted at launch is readable by anything running as me. An agent flag doesn't add a boundary, it adds a *scripted path* to the plaintext and a label that makes the path feel sanctioned. Break it and people write one more script; keep it and someone's "harmless" field is in a log by Friday.

2. **Per-item optional protection.** If protection is a checkbox, most items don't have it, and "the vault is encrypted" quietly means "the vault is encrypted at rest, as you, always." Remove the toggle and force the decision at creation — an item is sealed or it isn't, decided when you actually have context. What breaks: one extra step on every save, and the pleasant fiction that you're organised enough to classify retroactively. Worth it.

3. **The confirmation copy around sleep/screen lock.** "Closes protected items only" is technically true and functionally a lie, because it reads as *locked*. Two lock states with different scopes is a state machine the user is expected to hold in their head after walking away from the machine. Remove that reassurance and replace it with a single unambiguous "locked / not locked" indicator that is honest about what's still open. What breaks: nothing except the sense of safety the current text manufactures.

**Keep above all else:** the second key and the Touch ID gate on it. Not the lock menu, not the timeout, not the sync story — the seal. Every other control here is a UI affordance over data that is already readable by anything running as me; the second key is the only thing that isn't. Design everything else around protecting *it*, including making Vault > Lock the default on sleep rather than the exception.

One more: "opens at launch without a prompt" is doing a lot of unexamined work in this description. No prompt at launch plus a search palette bound to a global hotkey means the vault's unsealed contents are ambient, not gated. That's a defensible choice for non-protected fields. It's not a defensible default for the whole product, and the copy shouldn't let it sound like one.

## couple-02 / first-run

**Mira Castellanos (normal)**

Hola, perdona la pregunta tonta porque yo de esto no entiendo nada. En casa el Mac lo usamos mi hijo adolescente y yo, y lo que hago normalmente es cerrar la sesión cuando termino, pensando que así nadie ve mis cosas. ¿Eso me protege aquí o solo protege el botón \"Vault > Lock\"? Y lo que más me preocupa: si borro algo sin querer, ¿se puede recuperar de alguna manera? Es que en mi cabeza lo borrado ya no vuelve. Lo de que no haya nube me tranquiliza bastante, la verdad.

**Dana Whitfield (power)**

First ten minutes, from a bookkeeper's chair.

What I expected: a password manager. What I got: a database of records I have to design myself. Better for me long-term, worse for my first hour, because nothing told me that going in.

What I looked for, in order:

1. The Save button. I typed three records before I trusted that it just saves. Saving should be *visible* — a timestamp, a "saved" line, something. I write down when things changed for a living.

2. Whether the palette finds a field by the label *I* gave it. I renamed "Renewal date" to "Expires (ins.)", searched "expires", got nothing. That is the moment I stopped trusting the search box, and once I stop trusting it I stop using it.

3. Undo. I deleted a record on purpose. No undo, and no deleted-items bin I could find. With four hundred records that is not a quirk, that's the whole question.

4. Duplicate. My actual work is copying last year's record and changing four fields. I found no way to do that.

Two things I'd flag hard:

- The vault opens at launch with no prompt, and the palette types into whatever app has focus. That is a lot of reach for something that never asks. Tell me, in the app, exactly which items are reachable from the palette and which are sealed. Right now I'm assuming a search box searches everything I can see — and I suspect that assumption is wrong.

- "Non-sensitive fields as JSON" for agents: whose definition of non-sensitive? I want to see that list per item and tick it myself, not trust a default.

What it should have told me at each step: on first run, "records save as you type; there is no undo." When I mark an item protected, "these fields are hidden from search and from agents until Touch ID." When I search, show me a count of items withheld because they're sealed — silence that doesn't announce itself reads as "nothing there."

Where I stopped: at duplicate and undo. Also the toolbar type is small for me and I couldn't find a text-size setting.

No cloud sync I'm fine with. But no audit trail — what changed, and when — is a gap I feel immediately.

## couple-02 / daily-fill

**Dana Whitfield (power)**

I tested this as a bookkeeper who lives in spreadsheets, not code. I filled three vendor forms in other apps using the Control+Option+V palette, then added a client record, protected it, and went to lunch. Coming back: the protected item asked for Touch ID as described, and unlocking was quick. The important part for me is record consistency, so I tried to undo a field edit, duplicate an item, and delete the duplicate. I could not tell from the description whether an edit is undoable or whether deleting an item is truly reversible, and I did not see how duplicate detection works. I also noticed the item list can reorder itself depending on recent use, which makes me nervous when I am reconciling four hundred records; I would want a stable sort and a visible indication of what changed and when. My search expectation is that the palette searches every field I can see, including custom field names I invented, not just the standard ones. On accessibility, the palette text needs to respect larger system text sizing. On privacy, no cloud sync is good, but “opens at launch without a prompt” means anything not marked protected is readable to anyone at the unlocked Mac. For non-sensitive fields printed by a local agent, I would want a very clear boundary and an audit line showing which command read which item and when. What did the undo/duplicate/delete tests cost me? About ten minutes of hesitating before trusting the delete, and I would not store client data until I know whether the list order and the search scope are predictable.

**Mira Castellanos (normal)**

Leo esto con el Mac de casa delante, que lo comparto con mi hijo adolescente, y hay dos cosas que me dejan intranquila. La primera: "la bóveda se abre al arrancar sin pedir nada". Yo siempre he dado por hecho que con cerrar sesión en el Mac ya quedaba todo a salvo, y por lo que cuentas eso no es así: para cerrarlo TODO hay que entrar en Vault > Lock a mano, y dormir la pantalla o bloquear solo cierra lo protegido. La segunda: lo de marcar un elemento "para agentes" y que un comando imprima campos en JSON. Para quien no vivimos en el Mac, eso suena a otra puerta abierta, aunque digas que son campos no sensibles. ¿Podrías explicar cómo se ve en el día a día sin saber de terminal, y qué pasa si alguien de la casa borra un registro sin querer? Yo tiendo a cerrar las apps en vez de bloquearlas y siempre pienso que lo borrado ya no está, así que necesito saber si hay forma de recuperarlo y cuánto cuesta tener esto bajo control.

## couple-02 / trust

**Mira Castellanos (normal)**

A ver, me interesa pero me pierdo en un par de cosas. Yo comparto el Mac con mi hijo adolescente y siempre cierro sesión pensando que con eso ya queda todo a salvo. Pero aquí dice que la caja se abre al iniciar sin pedir nada... ¿cerrar sesión en el Mac cierra la caja o solo los elementos protegidos? ¿Y si simplemente salgo de la app en lugar de bloquearla, qué pasa? Eso es justo lo que yo hago siempre.

Otra duda: si borro un registro, ¿desaparece para siempre o se puede recuperar? Y como no hay nube, ¿cómo se supone que lo respaldo? Porque si se estropea el Mac, me quedo sin nada.

Y sobre lo de "qué evidencia me convencería": necesitaría ver que alguien que no soy yo, con mi sesión abierta, no puede leer mis documentos ni mis tarjetas. Sin eso, no me fío.

**Dana Whitfield (power)**

Bookkeeper here, so my questions are boring and very specific.

1) Audit trail. I need to see what changed, when, and what did it — including every failed Touch ID attempt and every time the agent export ran. If I can't print a change log, I can't tell a tampered record from a typo.

2) Search. The palette "searches a field, press Return, and the value is typed" — so which fields are indexed? If protected values are indexed, the palette is a leak. And does a hit tell me a sealed item exists at all? Be explicit: what's in the index before I unlock, and what's excluded until I do.

3) Delete and duplicate. Does delete purge the encrypted record, or just hide the row so it comes back on refresh? Can I undo it? And does it warn me when the same card number is already stored twice? I test those three things before I trust anything with a ledger-shaped list.

4) Locking. "Opens at launch without a prompt" plus "lock closes protected items only" means my unprotected notes and any agent-exported JSON sit there readable after I walk away from the machine. I'd want a full-vault lock on screen lock, or a hard guarantee that agent mode can never reach a protected field.

5) No cloud sync is the one thing that actually makes me consider it, and "encrypted on this Mac" I'd want spelled out: which cipher, which file, and does the plaintext ever hit disk in a temp file or a backup.

What I can't see today: any log at all, and any evidence that the ciphertext on disk is what it claims to be. Publish a change log, get the file format and the agent path independently audited, and I'd try it — with fake records first, real identity documents never.

## couple-02 / removal

**Dana Whitfield (power)**

Bookkeeper here — ~400 client and personal records, so I'll answer from the audit side, not the code side.

Three I'd remove:

1) The per-item "agents" toggle sitting on the item itself. What breaks: the JSON print for whoever automates off it. So don't delete the capability — move it to a read-only Export screen that lists the exact fields being printed before anything leaves. As it stands the switch is invisible until it's on, and my "non-sensitive" fields can change shape quietly when someone flips it.

2) The separate "inactivity timeout" setting. Fold it into the sleep/screen-lock rule and print one line naming which rule fired. What breaks: the ability to keep protected items open through a long call or a screen share — and after removing it, I can't tell from the vault why it locked, only that it did.

3) Any confirmation that lands *after* I've already typed and hit Return. What breaks: the second "are you sure" on a protected read. But Touch ID is already the gate, and a dialog I dismiss from muscle memory isn't a confirmation — it's a speed bump that trains me to mash keys.

Keep above all else: the search palette — but only if it finds a field by the name *I* gave it, including the ones I renamed. And tell me its scope. If it reaches sealed fields, show me that there's a match and make me Touch ID to reveal the value, rather than pretending the field isn't there. If search can't find a field I named, that record doesn't exist as far as I'm concerned.

One flag: "opens at launch without a prompt" is defensible for a local vault with no cloud sync, but I want the menu-bar icon to state unambiguously whether protected items are currently sealed. At 50, reading larger text, a 12px icon that changes subtly is not a status indicator — and "saving is visible" applies to locking, too.

