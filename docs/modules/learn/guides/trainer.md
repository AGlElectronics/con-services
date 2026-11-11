# Learn for trainers

This guide is for people in the Keycloak group `learn-trainer`. A trainer
creates courses and runs the courses they teach: content, learners,
sessions and grades. Who teaches which course is decided by a **training
manager** (`learn-manager`), not by trainers; see
[Admins and managers](admin.md).

**Words used here**

- **Staff**: the trainers of a course (plus admins). Only staff see a course
  before it is published.
- **Group link**: a Keycloak group connected to a course; its members are
  enrolled automatically.
- **Gradebook**: every learner's best quiz results on a course.

## Create and publish a course

1. Open **Teach** and fill in **New course** (title, summary), then
   **Create course**. You become its first trainer.
2. Add sections with **Add section**, then pages, quizzes and sessions with
   **Add page**, **Add quiz** and **Add session**.
3. For a quiz, add questions to the **question bank** (or import them from
   Moodle XML, GIFT, Aiken or CSV), then add them to the quiz as fixed
   questions or random draws. The quiz lists what still blocks publishing.
4. Choose **Publish**. Publishing fails while a quiz is not ready.

You see: the course shows **Published** on the Teach page.

To prepare a new edition, use **Copy course** on the Teach page: the copy
has the content and settings but no learners, and starts unpublished.

## Enrol learners

In the course editor, **People**:

1. Type a name in **Add a person** (at least a few letters).
2. Choose **Learner** next to the person. People marked *not signed in yet*
   come from your organisation's directory; Learn adds them for you.
3. To remove a learner, use the cross next to their name. Their progress is
   kept; enrolling them again restores it.

You only see names, not email addresses, and only people of your
organisation. You can't make someone a trainer or remove another trainer:
a training manager does that on **Course roles**.

## Link a group

Linking a Keycloak group enrols all its members as learners, and keeps it
up to date: new members are enrolled, people who leave the group become
*inactive* (no access, progress kept).

1. In the course editor, **Enrolment groups → Link a group (full path)**,
   pick the group, for example `/learn/volunteers-radio`, and choose
   **Link group**.
2. Learn enrols the members it can read from the directory at once and
   reports how many. **Sync now** refreshes the list; Learn also does this
   every five minutes.

You can only pick groups under the parent your organisation allows
(`LEARN_LINKABLE_GROUPS`, usually `/learn/...`). Ask a course manager for
other groups. When the panel warns that the **group directory is off**,
members are enrolled one by one as they sign in.

## Run an in-person session

1. Add a **session** to a section and create its time slots (date, time,
   place, capacity).
2. On the day, open the slot's **check-in** page. It shows a QR code that
   changes every 30 seconds. Put it on a screen at the door.
3. Learners scan it and are checked in; people without a booking join as
   walk-ins while seats are left.
4. The **roster** shows everyone. Correct attendance by hand (attended, no
   show, booked) where needed; every change is recorded in the audit log.

## Grades

Open **Grades** in the course editor. The gradebook lists every active
learner with, per quiz, their attempts, best percentage and whether they
passed, plus their due date and progress. **Question statistics** show which
questions people get wrong.

Only a course manager (`learn-admin`) can **reset** a quiz. A reset deletes
the attempts of the current cycle only; earlier rounds and certificates stay.

## Archive a course

When a course is over, choose **Archive** in the course editor. Learners
lose access, the course disappears from lists and nothing can be changed;
nothing is deleted. **Show archived** on the Teach page finds it again, and
**Unarchive** brings it back as it was.

## Troubleshooting

- **"Only a training manager (staff.manage) can make someone a trainer".**
  Ask a member of `learn-manager` to add the co-trainer on **Course roles**.
- **Someone is missing from the people search.** They are in another
  organisation, have never signed in while the directory is off, or were
  erased. You can't search by email.
- **"Trainers may only link the groups set in LEARN_LINKABLE_GROUPS".** The
  group is outside the allowed parent. Ask a course manager.
- **A linked group enrols nobody.** Check the group path is right, and ask
  your administrator whether Keycloak sends full group paths.
- **"This course is archived and read-only".** Unarchive it first.
- **A file upload is refused with "the file's contents are not a … file".**
  The file is not what its name says (for example a renamed document). Save
  it in a real image, audio or video format and upload again.
