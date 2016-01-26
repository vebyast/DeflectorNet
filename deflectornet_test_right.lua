-- This function returns the table that is the configuration for this client's
-- DeflectorNet. We make it a function, instead of a straight varaible, so we
-- can load HashablePosition before this happens. The table returned by this
-- function should have the following entries:
--   name: the name of this lua block's DeflectorNet client.
--   blocks: a table mapping HashablePositions to either true or string. If
--       true, then the component at this position is an incoming channel and
--       we're going to read from it. If a string, then this client will take
--       control of that component and use it to send messages as a channel with
--       the specified string name.
-- NOTE: the function name has an _underscore_ in it! This is so that you can
-- place this function declaration up with your own code, above where the
-- DeflectorNet object is defined.
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

-- last_sent_message = -1
function Update(I)
   DeflectorNet.update{I=I}

   repeat
   	  local message = DeflectorNet.receive_message{}
   	  if not message then break end
   	  I:Log(string.format("Received message of type %s on channel '%s':\n%s",
   						  message.mtype,
   						  message.cname,
   						  message.message))
   until false

   -- for cname,chan in pairs(DeflectorNet.incoming_channels) do
   -- 	  I:Log(string.format("Chan %s has %s floats", cname, Queue.len(chan.float_buffer)))
   -- end
   
   
   -- if I:GetTimeSinceSpawn() > last_sent_message + 2 then
   -- 	  DeflectorNet.queue_message{
   -- 		 message = "TESTING RIGHT!",
   -- 		 mtype = DeflectorNet.MessageTypes.string,
   -- 		 channel = "r1",
   -- 	  }
   -- 	  last_sent_message = I:GetTimeSinceSpawn()
   -- end
end


