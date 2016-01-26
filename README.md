# DeflectorNet

## A Networking Library for From the Depths LUA Blocks

Yes, I went there.

Given strings, floats, or Vector3s, packs the values into floats and publishes the floats for other LUA blocks to read by setting them as the values of components. Currently supports hydrofoils, which are not optimal - they tend to get clobbered by built-in AI - but functional. I'd planned to use shield projectors and didn't want to change the name when I realized they didn't include the `[0, 1)` range that DF packs messages into.

## How it Works

Encodes a message as a header float, a sequence of floats containing information, and a footer float. The header float contains the type of the message (string, number, vector, channel-name-broadcast, signal) and the number of floats constituting the message (not including the header). The footer is just -1 and serves to reduce computational overhead.

The system sends one float per tick. This implicitly relies on the LUA blocks executing in the same order ever frame, but so far this seems to be a reasonable assumption. This may fail after battle damage and reconstruction, but I think that, the way I've built this, this shoulnd't actually crash anything.

Once a non-footer value is seen, the system starts picking up floats. It reads the header, figures out how many values it expects to see, and waits until it has that many floats received before decoding them and putting them into a queue for being read out by the application.

All of your communication with this library is asynchronous. You call `DeflectorNet.update{}` at the beginning of every tick, which checks for incoming data and sets any flaots for queued outgoing data. You call `DeflectorNet.queue_message{ message=, mtype=, channel= }` to queue messages for sending. You call `DeflectorNet.receive_message{}` to attempt to receive a message, and will get a message if one has been received.

## Multiple Channels

This library supports multiple channels. Channels are unidirectional. Channels are initialized with a position in local coordinates (to make them able to hook back up after damage) and a name (which we use for programmer convenience and code portability).

Each channel uses a single block. A channel can have one sender but any number of receivers. No collision detection is implemented. Declare channels like this:

```lua
function DeflectorNet_get_init_args()
   return {
	  name = "right",
	  blocks = {
		 [HashablePosition(-2, 1, 3)] = true, -- left
		 [HashablePosition(-3, 1, 4)] = true, -- left
		 [HashablePosition(2, 1, 4)] = "r1", -- right
		 [HashablePosition(3, 1, 4)] = "r2", -- right
	  },
   }
end
```

This is a client that will name itself `right`. It will take ownership of two of the blocks, using them to back channels that it will name `r1` and `r2`. It will receive messages from channels backed by blocks at the other two positions. I've attempted to design this so the copy-paste between many clients won't be too bad.

One of the message types is a "set channel names" message. When sent, all of the clients listening to that block will, instead of queueing a message to be received by the application, remember the name of that channel.

When you attempt to receive a message, one of keys in the table that it returns is the name of the channel that that message came from. You should call `DeflectorNet.receive_message` in a loop to make sure you've drained the entire received message buffer every tick! This allows DeflectorNet to receive arbitrarily large numbers of messages per tick. Similarly, you must set a channel to send over when you call `DeflectorNet.queue_message`. DeflectorNet will handle the part of maintaining multiple queueus and setting multiple component blocks per tick.

DeflectorNet can handle an arbitrarily large number of channels per tick. Each channel can send one float per tick. A message is composed of two header/footer floats plus as many floats as the message requires. Three characters costs one float, a float costs one float, a vector costs three floats, and a signal costs zero floats.

## Usage Guide and Documentation

Functions and data types should be well-commented. There are two example programs included that serve to demonstrate a simple send-receive pair. I'll write more here later.

## Current Status

Very experimental. It works. Sort of. Channel names aren't rebroadcasted at any period so development is tricky. However, it does work - I can send and receive strings. I'm very happy with the interface, so that probably won't change.
