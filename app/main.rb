require 'app/screen.rb'
require 'app/ztext.rb'
require 'app/zobject.rb'
require 'app/zinstructions.rb'
require 'app/zmachine.rb'

def tick args
  # Unit Test Story File
  # You can find the source in the appendix section "Testing compliance", it's Czech
  # https://inform-fiction.org/zmachine/standards/z1point1/appc.html
  #   Uncomment section below and compare the output to czech.out3

  # args.state.zmachine ||= ZMachine.new args, 'app/czech.z3'
  # args.state.zmachine.tick args
  # return

  args.state.zmachine ||= ZMachine.new(args,
                                       'app/zork1.dat',
                                       # script: 'app/script.txt' # Run script
                                       # debug: true,             # Debug
                                      )

  # Use these commands inside ZORK to save/load progress
  # Save    :: Saves the game
  # Restore :: Retores the save

  # Script: You can run a script of commands
  #   Start the file with a seed at the top
  #   Followed by a series of commands separated by newlines

  # Debug prints opcodes
  #   left mouse runs instructions until a breakpoint is reached if any (:stop symbol from instruction)
  #     or input is being read by the zmachine
  #   right mouse runs 1 instruction and passes breakpoints

  args.state.zmachine.tick args
end
