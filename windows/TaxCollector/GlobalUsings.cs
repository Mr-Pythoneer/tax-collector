// TaxCore.TaskStatus collides with System.Threading.Tasks.TaskStatus (pulled in
// by ImplicitUsings). Everywhere in this project, TaskStatus means ours.
global using TaskStatus = TaxCore.TaskStatus;
