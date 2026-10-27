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

**Training snapshot**:
The athlete's profile and latest wellness, read from intervals.icu for each turn and given to the coach.
_Avoid_: Reference, cache, sync

**Activity**:
A recorded session read from intervals.icu.
_Avoid_: Ride, session, workout

**Activity review**:
The coach's read of one activity, at brief, default, or deep depth.
_Avoid_: Session review, analysis

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
The reset that archives the current conversation, saves memory, and shows the welcome. A waiting plan-save confirmation stays until it expires.
_Avoid_: Reset, new chat, clear

**Memory**:
What the coach keeps about the athlete between conversations. New conversation saves it.
_Avoid_: Profile, notes, context

**Language preference**:
The one choice, `Automatic` or a fixed language, that sets both the app's text and the coach's replies. A fixed language wins. Automatic uses the first supported language in the iPhone's preferred-languages list, or English when none is supported. The language picker is the only control. `ENDURAGENT_LANGUAGE` has no effect on iPhone, and message language never changes the result. This replaces message mirroring and the language override from B05.01 and B05.04 as an agreed difference.
_Avoid_: App language, reply language, coach language

### Calendar changes

**Workout review**:
The complete set of proposed calendar changes, shown as cards with totals and kept workouts and approved or canceled as one. It never saves a training plan.
_Avoid_: Proposal, preview, change set

**Kept workouts**:
Workouts on the affected dates that the review leaves unchanged, shown for context.
_Avoid_: Untouched workouts, context workouts

**Receipt**:
intervals.icu's answer that proves one change from a workout review was saved.
_Avoid_: Confirmation, result, success

**Unconfirmed change**:
A change sent to intervals.icu with no answer that says it was saved or refused, so it may or may not have been saved.
_Avoid_: Unknown write, uncertain change, pending change

**Check again**:
The action that reads the calendar to settle an unconfirmed change.
_Avoid_: Refresh, sync, reconcile

**Refreshed review**:
A workout review shown again because a workout in it changed on intervals.icu after it was first shown.
_Avoid_: Updated review, stale review, new proposal

### Training plans

**Training plan**:
A plan for a goal, built by the coach from the athlete's experience, FTP, weekly volume and schedule. It holds phases, weekly hours and sessions per phase, power zones and FTP test weeks.
_Avoid_: Program, schedule, block, plan (alone)

**Plan draft**:
A training plan the coach built in the conversation that the athlete has not saved. It changes nothing on the calendar and nothing in the saved plan.
_Avoid_: Skeleton, proposal, preview

**Saved plan**:
The one training plan the athlete saved with a plan-save confirmation, exactly as the athlete confirmed it. The coach sees its name, goal and length in every turn and can read the whole plan when it needs it. It follows the athlete to their other iPhones. A newer save replaces it, and History search shows each replacement.
_Avoid_: Active plan, current plan, stored plan

**Phase**:
A run of weeks in a training plan with one focus, such as base building, threshold or taper.
_Avoid_: Block, mesocycle, period

**Taper**:
The last phase before a race. It cuts volume and keeps intensity.
_Avoid_: Peak, rest block, deload

**Sample week**:
One example week of sessions for a volume level and schedule. It is the same for every phase. It is never saved and never put on the calendar.
_Avoid_: Template week, week plan, schedule

**Feasibility check**:
The coach's check of whether an FTP or W/kg goal is realistic for the athlete's experience. It gives a realistic first step and how many plan cycles the full goal may take.
_Avoid_: Goal assessment, readiness, prediction

**Plan-save confirmation**:
The card that asks the athlete to save one exact training plan, with Save plan and Cancel. It shows the plan's name, goal, length and phases, and the saved plan it would replace. It is separate from a workout review. It appears when the coach's reply ends well, expires ten minutes after that, and a newer one replaces it. Saving it never changes the calendar.
_Avoid_: Proposal, plan approval, plan review
