with AAA.Strings;

package Alr.Commands.Build is

   type Command is new Commands.Command with record
      Cov_Instr : aliased Boolean := False; -- Build for instrumented coverage
   end record;

   overriding
   function Name (Cmd : Command) return CLIC.Subcommand.Identifier
   is ("build");

   overriding
   function Switch_Parsing (This : Command)
                            return CLIC.Subcommand.Switch_Parsing_Kind
   is (CLIC.Subcommand.Before_Double_Dash);
   --  For the build command we want the args after -- to pass them to gprbuild

   overriding
   procedure Execute (Cmd  : in out Command;
                      Args :        AAA.Strings.Vector);

   function Execute (Cmd              : in out Commands.Command'Class;
                     Args             :        AAA.Strings.Vector;
                     Export_Build_Env :        Boolean;
                     Cov_Instr        :        Boolean := False)
                     return Boolean;
   --  Returns True if compilation succeeded. For invocations after some other
   --  command that already has set up the build environment we need to avoid
   --  redoing it, or it results in "variable already set" errors.

   overriding
   function Long_Description (Cmd : Command)
                              return AAA.Strings.Vector;

   overriding
   procedure Setup_Switches
     (Cmd    : in out Command;
      Config : in out CLIC.Subcommand.Switches_Configuration);

   overriding
   function Short_Description (Cmd : Command) return String
   is ("GPRbuild current working release");

   overriding
   function Usage_Custom_Parameters (Cmd : Command) return String
   is ("[--cov-instr] [--] [gprbuild switches and arguments]");

end Alr.Commands.Build;
