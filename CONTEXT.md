# Enduragent for iPhone

The native iPhone coach: a chat with an AI cycling coach that runs on the phone and reads training data from intervals.icu.

## Language

### Model access

**Access method**:
How the coach reaches and pays for a model: Credits or OpenRouter account.
_Avoid_: Billing mode, plan, provider

**Credits**:
Prepaid units bought in the app through the App Store and spent on the built-in model.
_Avoid_: Balance, tokens, coins

**Built-in model**:
The model Credits pay for, chosen by Enduragent and not by the athlete.
_Avoid_: Default model, our model

**OpenRouter account**:
The athlete's own OpenRouter account, connected by signing in, which pays for the model the athlete picks.
_Avoid_: Own key, BYOK, API key, personal key

**Provider**:
The company that hosts a model, such as OpenRouter or Anthropic.
_Avoid_: Vendor, backend

### Training data

**Athlete**:
The person the coach works for, who is the owner of the connected intervals.icu key.
_Avoid_: User, customer, account

**intervals.icu connection**:
The saved intervals.icu key and the athlete it belongs to. It lets the coach read training data and add workouts to the calendar.
_Avoid_: Integration, link, intervals account

### Conversation

**Conversation**:
The one ongoing chat between the athlete and the coach. There is never more than one.
_Avoid_: Chat, thread, session

**Archived conversation**:
A past conversation closed by New conversation and kept in History to read.
_Avoid_: Old chat, earlier chat, segment

**History**:
The list of archived conversations, kept to read and never continued.
_Avoid_: Archive, past chats, log

**Turn**:
One athlete message and the coach's work to answer it, from Send to a finished or stopped reply.
_Avoid_: Request, exchange, round

**Attempt**:
One try at answering a turn. The coach makes a few on its own, and Try again starts another.
_Avoid_: Run, call

**Notice**:
A sentence the app shows when something could not be done or needs the athlete, with the actions that fix it.
_Avoid_: Error, alert, banner, warning

**Try again**:
The action that repeats something that did not finish. For a turn, it answers the turn again and is offered only when nothing from the turn was saved; otherwise the notice asks for a new message.
_Avoid_: Retry, resend

**New conversation**:
The reset that archives the current conversation, saves memory, and shows the welcome.
_Avoid_: Reset, new chat, clear

**Memory**:
What the coach keeps about the athlete between conversations. New conversation saves it.
_Avoid_: Profile, notes, context

**Language preference**:
The one choice, `Automatic` or a fixed language, that sets both the app's text and the coach's replies. A fixed language wins. Automatic uses the first supported language in the iPhone's preferred-languages list, or English when none is supported. The language picker is the only control. `ENDURAGENT_LANGUAGE` has no effect on iPhone, and message language never changes the result. This replaces message mirroring and the language override from B05.01 and B05.04 as an agreed difference.
_Avoid_: App language, reply language, coach language

### Calendar changes

**Workout review**:
The complete set of proposed calendar changes, shown as cards with totals and kept workouts and approved or canceled as one.
_Avoid_: Proposal, preview, change set

**Kept workouts**:
Workouts on the affected dates that the review leaves unchanged, shown for context.
_Avoid_: Untouched workouts, context workouts
