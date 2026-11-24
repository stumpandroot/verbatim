# Voice test recording script

Record these 50 sentences in your own voice so the speech bench can measure Verbose on real audio. Every name is invented. Keep the recordings out of the repo and out of iCloud.

## Record

1. Make a folder on your Mac, such as `~/VerbatimBench`, and copy `clips.json` from this folder into it.
2. Open Voice Memos. For each sentence, make one recording and read the sentence once, at your normal dictation pace. Leave about half a second of quiet before and after.
3. Rename each recording to its ID, such as `hard-03`.
4. Select the recordings and drag them into the folder. They arrive as `hard-03.m4a`, which the bench reads.
5. If you misread a sentence, record it again. The text here must match what you said.

You can record a few groups and run the bench on those; missing clips are listed and skipped.

## How to say the hard names

| Name | Say it |
|---|---|
| Wrenly | REN-lee |
| Quillon | KWIL-un |
| Sjoberg | SHOW-berg |
| Pfenning Mill | FEN-ing mill |
| Aoife | EE-fa |
| Bly | bligh, rhymes with fly |
| Roe Street | row street |
| Thaddeus Krol | THAD-ee-us krawl |
| Xiomara | see-oh-MAR-a |
| Verdigris | VER-di-gree |

## Everyday sentences

Your desk, built-in or usual microphone, normal voice.

| ID | Read this |
|---|---|
| `plain-01` | Can you send me the invoice before lunch? I want to pay it today. |
| `plain-02` | I'm running about ten minutes late, so start without me. |
| `plain-03` | Let's move the review to Thursday at 2:30 and keep it to half an hour. |
| `plain-04` | The first cut is close, but the opening still feels slow to me. |
| `plain-05` | Please don't publish the page until I've checked the photos. |
| `plain-06` | We need three things from the shoot: wide shots, product details, and a short interview. |
| `plain-07` | Thanks for the quick turnaround. I'll send notes by the end of the day. |
| `plain-08` | I'm not sure the budget covers a second day, so let's plan for one. |

## Names that spell the way they sound

Same setup as plain.

| ID | Read this |
|---|---|
| `easy-01` | Brightwater approved the logo, so we can start on the packaging. |
| `easy-02` | Hollis Marsh wants to see two more color options by Friday. |
| `easy-03` | Send the proof to Copperfield Supply and copy me on it. |
| `easy-04` | The Larkspur catalog needs forty pages, not thirty-six. |
| `easy-05` | Dana Whitlock is out this week, so hold the contract until Monday. |
| `easy-06` | Fernbank moved the launch to the first week of March. |
| `easy-07` | I told Stonebridge we'd deliver the video on the twelfth. |
| `easy-08` | We're filming at Maple Run Farm on Saturday morning. |

## Hard names

Same setup as plain. Say each name the way you'd say it to a client.

| ID | Read this |
|---|---|
| `hard-01` | Wrenly signed off on the homepage this morning. |
| `hard-02` | Ask Quillon whether the trade show booth is ten feet or twenty. |
| `hard-03` | Mr. Sjoberg wants the interview finished before the holidays. |
| `hard-04` | The shoot at Pfenning Mill starts at seven, so pack the lights tonight. |
| `hard-05` | Aoife is writing the email series, and I'm reviewing it on Tuesday. |
| `hard-06` | Send Bly the invoice, and ask about the second deposit. |
| `hard-07` | The new office is on Roe Street, across from the bank. |
| `hard-08` | Thaddeus Krol is the contact for the retainer. |
| `hard-09` | Xiomara needs the brand guide in both print and web versions. |
| `hard-10` | The Verdigris rebrand uses green, cream, and a dark copper. |
| `hard-11` | Quillon and Wrenly both want the Sjoberg interview in the reel. |
| `hard-12` | Tell Aoife that Bly approved the Verdigris copy. |

## Sound-alike traps

Same setup as plain. These contain no Dictionary names; they test whether Verbose swaps one in by mistake.

| ID | Read this |
|---|---|
| `trap-01` | Stop by the shop on your way home and grab the hard drive. |
| `trap-02` | Put the chairs in a row along the back wall. |
| `trap-03` | A wren landed on the fence while we were filming. |
| `trap-04` | She set the quill on the desk next to the ink. |
| `trap-05` | The bright water in the background is blowing out the shot. |
| `trap-06` | We crossed the stone bridge and parked by the mill. |
| `trap-07` | The lark spurred the whole flock into the air. |
| `trap-08` | I'll fly out Sunday and be back by Wednesday. |

## Noisy place

A loud place: the shop, a running vehicle, or a room with music or people talking.

| ID | Read this |
|---|---|
| `noise-01` | Wrenly wants the proofs by Friday, and Brightwater wants them Monday. |
| `noise-02` | Please don't send the Sjoberg cut until I've heard the audio. |
| `noise-03` | I'm at the shop, so it's loud. Can you call me back at 4:15? |
| `noise-04` | Aoife said the budget is twelve thousand dollars, not fifteen. |
| `noise-05` | Put the chairs in a row and tell Bly we're ready. |
| `noise-06` | We need two cameras, three lights, and one backup battery. |

## Quiet voice

Your desk, but speak low, as you would with someone asleep nearby.

| ID | Read this |
|---|---|
| `quiet-01` | Quillon is on the other line, so I'll keep this short. |
| `quiet-02` | Move the Fernbank call to tomorrow morning. |
| `quiet-03` | I can't talk right now. I'll send the notes tonight. |
| `quiet-04` | Xiomara approved the second option. |

## AirPods

AirPods as the microphone, at your desk or walking.

| ID | Read this |
|---|---|
| `airpods-01` | Hollis Marsh and Thaddeus Krol are both on the email. |
| `airpods-02` | The Pfenning Mill shoot is confirmed for the ninth. |
| `airpods-03` | Remind me to order more tape and two memory cards. |
| `airpods-04` | Stop by Roe Street and pick up the signed contract. |

## Run the bench

Follow **Launch it** in `mac/Bench/README.md` with `-bench ~/VerbatimBench`. In the report, the `voice-hard` row's Names column is how often hard names came out right, and the `voice-trap` row's Wrong swaps column is how often a Dictionary name appeared when you didn't say it.
