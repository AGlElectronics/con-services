# Volunteer and front-desk guide

This page is for the people who use Stash at the logistics desk, in the
warehouse and at the Lost & Found desk: finding things by scanning,
printing labels, signing gear out and taking it back, packing for an event,
and Lost & Found. You need a Stash role; if Stash says *no Stash role yet*,
ask your team lead (roles are on the [Admin guide](admin-guide.md#who-can-do-what)).

Words used here:

- **Item:** one kind of thing Stash tracks, for example *XLR cable 10 m*.
  An item can have many units (*15 owned*).
- **Asset tag:** the item's code, printed on its label, for example
  `ST000042`.
- **Sign-out:** a record that a department took some units, when, and when
  they should come back. Its number looks like `SO-2026-00012`.
- **Available:** units owned, minus damaged, lost and signed out.

## Scanning

You can find an item or a Lost & Found report by its code in three ways:

1. **USB barcode scanner** (laptop at the desk): click **Scan** in the
   sidebar, then scan. The scanner types the code and presses Enter.
2. **Phone or tablet camera:** click **Scan**, then **Use camera**, and
   allow the camera. Hold the label 10 to 20 cm from the camera; it reads
   barcodes and QR codes. On a phone Stash uses the rear camera.
3. **Your phone's own camera app** on a **QR label:** the QR code holds a
   Stash link, so the phone offers to open it. After signing in you land on
   the item (or the Lost & Found report) directly.

A code that belongs to nothing shows *No item with this code*; with the
right permission you can assign it to an item from there. Lost & Found
numbers (`LF-0003`, also typed as `lf3`) open the report.

## Printing labels

1. Open the item and click **Print label**. A print page opens.
2. Pick the **label size** of your printer (saved in this browser).
3. Pick the **code style**:
    - *Barcode* for USB scanners;
    - *QR code* if people will scan with phones. It still contains the code
      as text next to it.
4. Keep **Print the organisation logo** ticked unless the label is tiny.
5. Set **Copies**, check the preview, click **Print**. In the print dialog
   choose the label printer and *Actual size* (no scaling).

An item without an asset tag shows *No code yet*: click **Generate code** on
the item page first (or type a code in *Override code*).

## Signing gear out

**Fast sign-out** (one item, a few seconds):

1. Go to **Items**, search (for example `power strip`). The row shows
   *Available 13 / 15 owned*.
2. Click **Sign out** on the row.
3. Pick the **department** that takes it and type who receives it. If the
   setting *Require barcode scan to sign out* is on, scan the item's label.
4. Confirm. The sign-out is created and signed out at once.

**Sign-out with several items:** **Sign-outs → New sign-out**, add the
items and quantities (scan or search), set the department, the recipient
and **Expected return**, then click **Sign out N units**. It is signed out
at once.

**From a packing list:** open the list and click **Create sign-out**. Stash
makes a draft with every line of the list; open it, check it, and click
**Confirm**. Availability is checked again then.

If an item does not have enough units, Stash says *item "Radio" has only 2
available (you asked for 3)*. Ask logistics, or sign out fewer.

## Taking gear back

1. Open the sign-out (search its number in **Sign-outs**, or scan an item
   and open its active sign-out).
2. Under **Process return**, enter for every line how many units came back
   (**Returned**), were used up (**Consumed**), are **Lost** or came back
   **Damaged**.
3. Click **Submit return**. Until every unit is accounted for, the sign-out
   is *partially returned*; then it is *returned*, and logistics can
   **Close** it. Used-up units leave the stock; lost and damaged ones are
   counted on the item until someone marks them found or repaired.

Sign-outs past their expected return show in the sidebar as *overdue*.

## Packing for an event

1. **Packing lists → New list**: a name (*Main stage Friday*), the
   department and the date.
2. In the list, type an item's name under **Add an item** and pick it; set
   **Needed**. The **Available** column turns red when there are not
   enough units.
3. While packing, set **Packed** for each line, or click the tick to mark
   the line fully packed.
4. When everything is packed, click **Create sign-out** (see above).

## Asking for gear

Need something logistics should provide or buy? **Requests → New request**:
what, how many, for which department, by when and why. Logistics approves,
orders, fulfils or rejects it; the status shows on the list. You can cancel
your own request while it is open.

## Lost & Found desk

**Log an item:**

1. **Lost & Found → New report**. Choose **Found** (handed in) or **Lost**
   (a guest is looking for something).
2. Enter what it is, where it was found or lost, and the guest's name and
   contact if there is one. Take a photo.
3. Save. Stash gives it a number, for example `LF-0042`. Print the label
   and stick it on the item (or on the guest's receipt).

**Tell the guest on Telegram** (when the desk uses the Telegram bot):

1. On the report, the *Telegram* box shows what the guest sends: for
   example `/start LF0042` to `@examplecon_lostfound_bot`. Show them, or
   write it on their receipt.
2. When they have sent it, the box says *Guest linked*.
3. When there is news, click **Notify guest**. Leave the message empty for
   the standard text (*News about your Lost & Found report LF-0042 (Blue
   backpack): please come to the Lost & Found desk.*) or write your own.

**Hand an item back:** check the guest describes it, then **Mark returned**
and enter who took it. **Close report** is for items nobody claimed
(donated, disposed).

Guests' names and contacts are deleted automatically some time after a
report is closed; do not copy them anywhere else.

## Troubleshooting

**The camera does not start.** The browser needs camera permission, and
Stash must be opened over `https://`. On iPhone use Safari. Close other apps
that use the camera.

**The camera does not read the label.** Hold it steady 10 to 20 cm away in
good light; a damaged or glossy label may need the USB scanner or typing
the code.

**Scanning a QR label with the phone camera shows a sign-in page.** Sign
in; Stash then opens the item.

**"a barcode scan is required"** when signing out: the setting *Require
barcode scan* is on; scan the item's label in the sign-out dialog.

**"department … does not exist"** in the item form: only logistics may add
departments, categories and locations. Pick an existing one, or ask them.

**I cannot see Lost & Found / Sign-outs in the menu.** Your role does not
include it. Ask your team lead.

**The label prints too small or cut off.** Pick the right label size, and
in the print dialog choose *Actual size* and no margins.
