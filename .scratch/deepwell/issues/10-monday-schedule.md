# 10: Monday schedule and notification

**What to build:** The weekly menu builds automatically every Monday at 07:00, or on the first launch after that if the Mac was off or asleep, and a notification says it's ready. Topics picked in recent weeks are deprioritised.

**Blocked by:** 09

**Status:** ready-for-agent

- [ ] Menu builds at Monday 07:00 when the app is running
- [ ] A missed Monday is caught up on next launch, at most once per week
- [ ] Notification opens the menu
- [ ] Recently picked topics are passed to the model and appear less often (tested with a stubbed model)
