-- ######################################################################
-- ######################################################################
-- Hashable Positions. A vector-ish data type that can be used a table key
-- ######################################################################
-- ######################################################################

local hashablepositionscache = {}
function HashablePositionToV3(hp)
   return Vector3(hp.x, hp.y, hp.z)
end
function HashablePositionFromV3(v)
   return HashablePosition(v.x, v.y, v.z)
end
function HashablePosition(x, y, z)
   local hpc = hashablepositionscache
   if (hpc[x] == nil) then hpc[x] = {} end
   if (hpc[x][y] == nil) then hpc[x][y] = {} end
   if (hpc[x][y][z] == nil) then hpc[x][y][z] = {x=x, y=y, z=z} end
   return hpc[x][y][z]
end

-- #############################################################################
-- #############################################################################
-- quick queue library, stolen from http://www.lua.org/pil/11.4.html
-- #############################################################################
-- #############################################################################
Queue = {}
function Queue.new ()
   return {first = 0, last = -1}
end
function Queue.pushleft (queue, value)
   local first = queue.first - 1
   queue.first = first
   queue[first] = value
end
function Queue.popright (queue)
   local last = queue.last
   if Queue.empty(queue) then return nil end
   local value = queue[last]
   queue[last] = nil         -- to allow garbage collection
   queue.last = last - 1
   return value
end
function Queue.peekright (queue)
   local last = queue.last
   if Queue.empty(queue) then return nil end
   return queue[last]
end
function Queue.empty (queue)
   return queue.first > queue.last
end
function Queue.len (queue)
   return queue.last - queue.first + 1
end
function Queue.iter(queue)
   local i = queue.last + 1
   return function()
	  i = i - 1
	  if i >= queue.first then return queue[i] end
   end
end
function Queue.to_array(queue)
   local arr = {}
   for value in Queue.iter(queue) do
	  arr[#arr + 1] = value
   end
   return arr
end

-- #############################################################################
-- #############################################################################
-- functional reduce function, stolen from http://stackoverflow.com/a/8695525
-- #############################################################################
-- #############################################################################

table.foldl = function (list, fn, accum)
   local acc = accum or nil
   for k, v in ipairs(list) do
	  if 1 == k then
		 if accum then
			acc = fn(accum, v)
		 else
			acc = v
		 end
	  else
		 acc = fn(acc, v)
	  end 
   end 
   return acc 
end

-- #############################################################################
-- #############################################################################
-- a full-duplex communication library that sends four characters per second by
-- encoding them in floats and setting them in a deactivated shield projector
-- that's stored next to each lua box. each lua box is given its own shield
-- projector
-- #############################################################################
-- #############################################################################

-- some things to remember:
-- * DeflectorNet is _not_ threadsafe.
-- * DeflectorNet requires a global initialization.
-- * DeflectorNet uses shield projectors. it will _fail_ if something on your
--   craft takes over its shields.

DeflectorNet = {}

-- DeflectorNet.DEFAULT_N_CONSUME = 6 -- f64
-- DeflectorNet.DEFAULT_EXPONENT = 51 -- f64

DeflectorNet.DEFAULT_N_CONSUME = 3 -- f32
DeflectorNet.DEFAULT_EXPONENT = 22 -- f32

DeflectorNet.BLOCK_TYPES = { 8 }

-- a table mapping channel names to objects with the following:
--   float_buffer: a Queue containing floats that have been received but not yet
--       decoded into a message
--   message_buffer: a Queue containing messages that haven't yet been read out
--   ctype: the From the Depths component type for the block that backs this
--       channel
--   cindex: the From the Depths component index for the block that backs this
--       channel
--   pos: the location (as a HashablePosition) of the block that backs this
--       channel. used for rescans in case of damage.
--   clname: the name of the client that owns this channel
DeflectorNet.incoming_channels = {}


-- a table mapping channel names to objects with the following:
--   float_buffer: a Queue containing floats that have been encoded but not yet
--       sent
--   ctype: the From the Depths component type for the block that backs this
--       channel
--   cindex: the From the Depths component index for the block that backs this
--       channel
--   pos: the location (as a HashablePosition) of the block that backs this
--       channel. used for rescans in case of damage.
DeflectorNet.outgoing_channels = {}
-- this client's name
DeflectorNet.hostname = ''
-- whether we've initialized
DeflectorNet.inited = false

DeflectorNet.MessageTypes = {
   string = 1,					-- encodes a string
   number = 2,					-- encodes a number
   vector = 3,					-- encodes a Vector3 or HashablePosition
   nameset = 4,					-- a string. broadcasts the name of this client
   -- and channel, joined with a comman (,). Should
   -- only be used during init
   signal = 5,					-- carries no data, is just the signal
}

-- initializes this lua block's deflectornet client. It will read in the
-- manually defined DeflectorNet.initargs table and use that information to
-- configure the DeflectorNet system.
-- 
-- arguments: a table of:
--   I: the FTD interface object
function DeflectorNet.init_system(args)

   if DeflectorNet.inited then return end

   local I = args.I
   
   local initargs = DeflectorNet_get_init_args()
   DeflectorNet.hostname = initargs.name
   local blocks = initargs.blocks

   local created_channels = 1
   for _,ctype in ipairs(DeflectorNet.BLOCK_TYPES) do
	  for cidx = 0,I:Component_GetCount(ctype)-1 do
		 local pos = HashablePositionFromV3(I:Component_GetLocalPosition(ctype, cidx))
		 local res = blocks[pos]
		 if res == true then -- value is specifically equal to boolean true, incoming
			DeflectorNet.incoming_channels[string.format("unnamed_in%s", created_channels)] = {
			   float_buffer = Queue.new(),
			   message_buffer = Queue.new(),
			   ctype = ctype,
			   cindex = cidx,
			   pos = pos,
			   clname = string.format("unknown_cl%s", created_channels),
			   last = -1,
			}
			created_channels = created_channels + 1
		 elseif res then		-- value is non-nil, it's a string, outgoing
			I:Component_SetFloatLogic(ctype, cidx, -1)
			DeflectorNet.outgoing_channels[res] = {
			   float_buffer = Queue.new(),
			   ctype = ctype,
			   cindex = cidx,
			   pos = pos,
			}
			DeflectorNet.queue_message{
			   message = "",	-- not used on a nameset
			   mtype = DeflectorNet.MessageTypes.nameset,
			   channel = res,
			}
		 end
	  end
   end

   DeflectorNet.inited = true
end


-- if there's a message to be received, return it.
-- 
-- NOTE: multiple messages can be received per tick! You need to call this in a
-- loop and handle its results until it's returned all its new messages. The
-- current implementation of this system allows an _arbitrarily large_ number of
-- messages to be received per tick.
-- 
-- arguments: a table of:
--   cnames [OPTIONAL]: an array of channel names to receive messages from. If
--       not specified, receive messages from all channels.
--
-- return value: a table of:
--   message: the message itself
--   mtype: the type of the value that was returned. see
--       DeflectorNet.MessageTypes.
--   cksum_result: whether the checksum matched
--   cname: string value, the name of the channel that returned this message
function DeflectorNet.receive_message(args)
   local chans
   if args.cname then
	  chans = args.cname
   else
	  chans = {}
	  for cname,_ in pairs(DeflectorNet.incoming_channels) do
		 chans[#chans+1] = cname
	  end
   end
   
   for _,cname in ipairs(chans) do
	  local chan = DeflectorNet.incoming_channels[cname]
	  if not Queue.empty(chan.message_buffer) then
		 local result = Queue.popright(chan.message_buffer)
		 result.cname = cname
		 return result
	  end
   end
   return nil
end

-- checks all of the ship's shield projectors that have been detected to be
-- senders to see if they've sent any new data. if they have, receive it and put
-- it into the received-messages queue. Go through all our outgiong float
-- buffers and, if they have characters to send, send the first. Call this at
-- the top of your Update function. Automatically handles initing deflectornet
-- if it hasn't been initialized so you don't have to worry about it.
--
-- arguments: a table of:
--   I: the FTD interface object
function DeflectorNet.update(args)
   local I = args.I

   if not DeflectorNet.inited then
	  DeflectorNet.init_system{I=I}
   end

   -- first pass: grab new floats from blocks
   for cname, chan in pairs(DeflectorNet.incoming_channels) do
	  local newval = I:Component_GetFloatLogic(chan.ctype, chan.cindex)
	  if newval ~= -1 then
		 I:Log(string.format("read float from %s,%s (at pos %s,%s,%s): %s",
							 chan.ctype,
							 chan.cindex,
							 chan.pos.x, chan.pos.y, chan.pos.z,
							 newval))
		 Queue.pushleft(chan.float_buffer, newval)
	  end
   end
   -- second pass: check to see if we've finished receiving any messages
   local pending_name_changes = {}
   for cname, chan in pairs(DeflectorNet.incoming_channels) do
	  if not Queue.empty(chan.float_buffer) then
		 local message = DeflectorNet.try_decode_message{buffer = chan.float_buffer, I = I}
		 if message ~= nil then
			I:Log(string.format("decoded message from %s,%s (at pos %s,%s,%s) to mtype %s of length %s (buffer: %s)",
								chan.ctype,
								chan.cindex,
								chan.pos.x, chan.pos.y, chan.pos.z,
								message.header.mtype,
								message.header.mlength,
								Queue.len(chan.float_buffer)))
			
			if message.header.mtype == DeflectorNet.MessageTypes.nameset and message.message ~= nil then
			   -- if it's a nameset, then set the name and don't return it
			   pending_name_changes[cname] = message.message
			else
			   -- if it's not a nameset, then return it
			   Queue.pushleft(chan.message_buffer, message)
			end
		 end
	  end
   end
   
   -- do any name changes
   for orig, mess in pairs(pending_name_changes) do
	  DeflectorNet.incoming_channels[mess.cname] = DeflectorNet.incoming_channels[orig]
	  DeflectorNet.incoming_channels[orig] = nil
	  DeflectorNet.incoming_channels[mess.cname].clname = mess.clname
   end
   
   -- third pass: send new floats from our own blocks
   for cname, chan in pairs(DeflectorNet.outgoing_channels) do
	  if not Queue.empty(chan.float_buffer) then
		 local value = Queue.popright(chan.float_buffer)
		 I:Log(string.format("setting float logic %s,%s (at pos %s,%s,%s) to %s",
		 					 chan.ctype,
		 					 chan.cindex,
		 					 chan.pos.x, chan.pos.y, chan.pos.z,
		 					 value))
		 I:Component_SetFloatLogic(chan.ctype,
								   chan.cindex,
								   value)
	  end
   end
end


-- check to see if a message can be decoded from the given buffer. If so, pops
-- if off the queue, decodes it, and returns it.
-- 
-- arguments: a table of:
--   buffer: the buffer to try to pull a message off the front of
--
-- returns: the same as DeflectorNet.decode_message
function DeflectorNet.try_decode_message(args)
   local buffer = args.buffer
   
   local header = DeflectorNet.decode_header_float(Queue.peekright(buffer))
   -- need the header plus the length of the message
   if Queue.len(buffer) >= header.mlength + 1 then
	  Queue.popright(buffer) -- pop off the header, since we don't need it any more
	  return DeflectorNet.decode_message{
		 header = header,
		 buffer = buffer,
		 I = args.I,
	  }
   end
   return nil
end


-- takes a queue of floats and pops floats off until it's decoded a
-- message. Returns the message.
-- 
-- arguments: a table of:

--   header: a header struct from decode_header_float. this function assumes
--       that this float has already been popped off the front of the queue of
--       floats in the buffer argument!
--   buffer: a buffer to read floats out from. will be _modified_ as this
--       function pops the message-containing floats off it!
--
-- return value: a table of:
--   message: the message itself
--   mtype: the type of the value that was returned. see
--       DeflectorNet.MessageTypes.
--   cksum_result: whether the checksum matched
function DeflectorNet.decode_message(args)
   local header = args.header
   local buffer = args.buffer
   
   local floats = {}
   for idx = 1, header.mlength do
	  floats[idx] = Queue.popright(buffer)
   end

   local compute_cksum = DeflectorNet.compute_cksum(floats)
   local cksum_result = compute_cksum == header.cksum
   
   local message
   if header.mtype == DeflectorNet.MessageTypes.string then
	  message = DeflectorNet.decode_string(floats)
	  args.I:Log(string.format("decoded string: %s -> %s", #floats, message))
   elseif header.mtype == DeflectorNet.MessageTypes.number then
	  message = floats[1]
   elseif header.mtype == DeflectorNet.MessageTypes.vector then
	  message = Vector3(floats[1], floats[2], floats[3])
   elseif header.mtype == DeflectorNet.MessageTypes.nameset then
	  local namestring = DeflectorNet.decode_string(floats)
	  local it = string.gmatch(namestring, "[^,]+")
	  if it ~= nil then
		 local clname = it()
		 local cname = it()
		 message = {
			clname = clname,
			cname = cname,
		 }
	  else
		 args.I:Log("nameset didn't match: %s", namestring)
		 message = nil
	  end
   elseif header.mtype == DeflectorNet.MessageTypes.signal then
	  message = {}
   end

   return {
	  message = message,
	  mtype = header.mtype,
	  cksum_result = cksum_result,
	  header = header,
   }
end


-- encodes and enqueues a message on the given outgoing channel.
-- 
-- arguments: a table of:
--   message: an object containing the message
--   mtype: an element of DeflectorNet.MessageTypes that specifies how to encode
--       the message.
--   channel: the name of the channel on which to enqueue the message for
--       transmission
--
-- returns success.
function DeflectorNet.queue_message(args)
   local floats

   if args.mtype == DeflectorNet.MessageTypes.string then
	  floats = DeflectorNet.encode_string{message=args.message}
   elseif args.mtype == DeflectorNet.MessageTypes.number then
	  floats = {
		 [1] = args.message
	  }
   elseif args.mtype == DeflectorNet.MessageTypes.vector then
	  floats = {
		 [1] = args.message.x,
		 [2] = args.message.y,
		 [3] = args.message.z,
	  }
   elseif args.mtype == DeflectorNet.MessageTypes.nameset then
	  local namestring = DeflectorNet.hostname .. "," .. args.channel
	  floats = DeflectorNet.encode_string{message=namestring}
   elseif args.mtype == DeflectorNet.MessageTypes.signal then
	  floats = {}
   end

   local header = DeflectorNet.make_header_float{
	  mtype = args.mtype,
	  floats = floats,
   }

   local buffer = DeflectorNet.outgoing_channels[args.channel].float_buffer
   -- transmit the header first
   Queue.pushleft(buffer, header)
   -- followed by the floats in order
   for _,fl in pairs(floats) do
	  Queue.pushleft(buffer, fl)
   end
   -- and the footer, which sets the block to a value that we won't read out
   -- later.
   Queue.pushleft(buffer, -1)
end

-- creates a float containing the header for a message, which will be a single
-- float. Again, uses the mantissa for the data and reserves the exponent for
-- normalizing everything into [0, 1) for transmission.
-- 
-- arguments: a table of:
--   mtype: an element of DeflectorNet.MessageTypes that specifies how to encode
--       the message.
--   floats: a list of floats that the header will be wrapping. used for things
--       like length and checksumming.
--
-- returns: nil if failure, otherwise the float.
function DeflectorNet.make_header_float(args)
   local mtype = args.mtype
   local mlength = #args.floats
   local cksum = DeflectorNet.compute_cksum(args.floats)
   local header = 0

   -- -- this assumes f64s.
   -- header = header + cksum -- lowest 16 bits for checksum, 16 bits used
   -- header = header + (mtype * (2^16)) -- 4 bits for message type, 20 bits used
   -- header = header + (mlength * (2^20))	-- 16 bits for message length, 36 bits used

   -- this works with f32s.
   header = header + mtype		-- 4 bits for message type
   header = header + (mlength * (2^4))
   
   header = header / (2^DeflectorNet.DEFAULT_EXPONENT)
   return header
end

function DeflectorNet.compute_cksum(floats)
   -- the best solution for this is probably going to involve translating our
   -- floats back into bits again, which I'm not eager to do. For now, use a big
   -- random constant.
   return 11313
end

-- decodes a float into a table with the properties encoded by the message
-- header. Elements:
--   mlength: declared message length
--   mtype: message data types
--   cksum: declared checksum value
function DeflectorNet.decode_header_float(f)
   local fl = f * (2^DeflectorNet.DEFAULT_EXPONENT)

   -- -- this assumes f64s
   -- local cksum = fl % (2^16)
   -- fl = (fl - cksum) / (2^16)
   -- local mtype = fl % (2^4)
   -- fl = (fl - mtype) / (2^4)
   -- local mlength = fl % (2^16)
   -- fl = (fl - mlength) / (2^16)

   -- this assumes f32
   local mtype = fl % (2^4)
   fl = (fl - mtype) / (2^4)
   local mlength = fl
   fl = (fl - mlength)

   -- header should really be zero now, but since this thing won't tolerate
   -- crashes we can't assert it like we usually would.
   
   return {
	  mlength = mlength,
	  mtype = mtype,
	  cksum = cksum,
   }
end

-- given a string, losslessly encodes it into an array of floating-point
-- values. Uses the mantissas of the floats to encode the characters, uses the
-- exponents to ensure that the floats are all in [0, 1).
--
-- arguments: a table of:
--   message: the string to encode
-- 
-- return value: a table of:
--   floats: an array of floats containing the string message, suitably encoded.
function DeflectorNet.encode_string(args)
   local float_buffer = Queue.new()
   local encode_result = {}
   repeat
	  encode_result = DeflectorNet.encode_chars{
		 message = args.message,
		 start = encode_result.cont
	  }
	  Queue.pushleft(float_buffer, encode_result.f)
   until encode_result.done
   return Queue.to_array(float_buffer)
end

-- given an array of characters, losslessly encodes into a floating-point value
-- a number of characters from the front (lowest indices) of the array. Uses the
-- mantissa of the float to encode the character, reserving the exponent so that
-- it can set it to a very small number in order to ensure that the result has
-- an actual value between 0 and 1.
--
-- arguments: a table of:
--   arr: the array to consume characters from
--   start: the index to start consuming from
-- 
-- return value: a table of:
--   n: how many characters were consumed and encoded
--   f: a float containing the n characters that were consumed, suitably
--       encoded.
--   cont: the index of the first unconsumed character in the string after the
--       consumed portion. In a loop over a long message, this can be fed
--       directly into the start param of the next invocation of this function.
--   done: a bool indicating whether the last value in the array has been
--       consumed.
function DeflectorNet.encode_chars(args)
   local message = args.message
   local idx_start = args.start or 1
   local n_consume = DeflectorNet.DEFAULT_N_CONSUME
   local done = false

   local idx_end = idx_start + n_consume - 1
   if idx_end >= message:len() then
	  done = true
	  idx_end = message:len()
	  n_consume = message:len() - idx_start + 1
   end
   
   local f = 0.0
   for idx = idx_start, idx_end do
	  local place = (idx - idx_start) * 8
	  f = f + message:byte(idx) * 2^(place)
   end
   f = f / (2^DeflectorNet.DEFAULT_EXPONENT)
   
   return {
	  cont = idx_end + 1,
	  n = n_consume,
	  f = f,
	  done = done,
   }
end


-- given an array of floats containing a string, decodes the floats into the
-- string and returns it.
-- 
-- arguments: the float array to decode characters from
-- 
-- return value: the string that resulted from the decoding process
function DeflectorNet.decode_string(floats)
   local result = ""
   for _,fl in ipairs(floats) do
	  result = result .. DeflectorNet.decode_string_part(fl).result
   end
   return result
end

-- given a single float containing a short string, decodes the float into a
-- short string and returns it.
-- 
-- arguments: a table of:
--   f: the float to decode characters from
-- 
-- return value: a table of:
--   result: the string that resulted from the decoding process
function DeflectorNet.decode_string_part(f)
   local f = f * (2^DeflectorNet.DEFAULT_EXPONENT)

   local result = ""

   while f > 0 do
	  local f_lowest_bits = f % (2^8)
	  result = result .. string.char(f_lowest_bits)
	  f = f - f_lowest_bits
	  f = f / (2^8)
   end
   
   return {
	  result = result,
   }
end



function DeflectorNet.list_blocks(I)
   for _,ctype in ipairs(DeflectorNet.BLOCK_TYPES) do
	  for cidx = 0,I:Component_GetCount(ctype)-1 do
		 local pos = I:Component_GetLocalPosition(ctype, cidx)
		 I:Log(string.format("component %s,%s at: %s,%s,%s",
							 ctype, cidx,
							 pos.x, pos.y, pos.z))
	  end
   end
   I:Log("")
end
